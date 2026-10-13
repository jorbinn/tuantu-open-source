/* 团图 Tuantu 队员端 SPA（Vue 3 全局构建，无构建步骤） */
"use strict";

/* ---------------- 工具 ---------------- */
const $api = async (url, opts = {}) => {
  const r = await fetch(url, {
    headers: { "Content-Type": "application/json" }, ...opts,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  if (r.status === 401) { app && (app.user = null); throw new Error("请先加入"); }
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.detail || "请求失败");
  return data;
};

const toast = (msg, ms = 2200) => {
  const t = document.getElementById("toast");
  t.textContent = msg;
  t.classList.add("show");
  clearTimeout(t._tm);
  t._tm = setTimeout(() => t.classList.remove("show"), ms);
};

/* taken_at 存的是「相机本地时间按 UTC 解释」，因此用 UTC 系列方法还原墙钟时间 */
const fmtTime = (t) => {
  if (!t) return "";
  const d = new Date(t * 1000);
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())} ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`;
};
const dayKey = (t) => {
  if (!t) return "unknown";
  const d = new Date(t * 1000);
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())}`;
};
const weekdayCn = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

const RAW_EXTS = new Set(["cr2","cr3","nef","arw","dng","orf","rw2","raf","pef","srw","x3f","3fr","iiq"]);
/* 浏览器能直接内联预览的格式（其余详情页退回缩略图） */
const VIEWABLE = new Set(["jpg","jpeg","png","gif","webp","bmp","avif",
  "mp4","m4v","mov","webm","mp3","m4a","wav","flac","ogg"]);

/* Web Share（「存储图像」直接进相册）只在 HTTPS 安全上下文可用，能力探测 */
const canShareFiles = () => {
  try {
    if (!navigator.canShare || !window.File) return false;
    return navigator.canShare({ files: [new File([new Uint8Array([1])], "t.jpg", { type: "image/jpeg" })] });
  } catch (e) { return false; }
};
const IS_IOS = /iPhone|iPad|iPod/.test(navigator.userAgent);

const triggerDownload = (url, name) => {
  const a = document.createElement("a");
  a.href = url;
  if (name) a.download = name;
  document.body.appendChild(a); a.click(); a.remove();
};
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

const app = Vue.createApp({
  data() {
    return {
      user: null, tab: "swipe",
      status: { pending: 0, total: 0, persons: 0, faces_ready: false },
      /* 加入页 */
      joinName: localStorage.getItem("tt_name") || "",
      joinCode: "", joinErr: "", joining: false,
      /* 滑动 */
      dealView: "timeline", batch: { no: 0, cards: [], remaining: 0 },
      batchView: "timeline", cardIdx: 0, dx: 0, dragging: false, flying: 0, batchDone: false,
      decidedKeeps: [], batchNo: 0, viewLabel: "时间线",
      /* 保存到相册：0 待取图 1 取图中 2 分组存入中 3 完成 */
      savePhase: 0, saveFiles: null, saveChunk: 0, saving: false,
      /* 相册 */
      galView: "all", galItems: [], galCursor: null, galEnd: false, galLoaded: false,
      /* 人物 */
      persons: [],
      /* 上传 */
      upQueue: [], upProgress: 0, upResult: null, uploading: false,
      /* 详情 */
      detail: null,
    };
  },
  computed: {
    curCard() { return this.batch.cards[this.cardIdx] || null; },
    nextCard() { return this.batch.cards[this.cardIdx + 1] || null; },
    keptCards() { return this.decidedKeeps; },
    detailSrc() {
      if (!this.detail) return "";
      return VIEWABLE.has((this.detail.ext || "").toLowerCase())
        ? `/api/asset/${this.detail.id}/raw` : this.detail.thumb;
    },
    detailIsVideo() {
      return this.detail && this.detail.kind === "video" &&
        VIEWABLE.has((this.detail.ext || "").toLowerCase());
    },
    canShare() { return canShareFiles(); },
    isIOS() { return IS_IOS; },
    saveGroups() { return Math.ceil((this.saveFiles ? this.saveFiles.length : 0) / 10) || 0; },
    saveBtnLabel() {
      const n = this.keptCards.length;
      if (this.savePhase === 1) return `取原图中 ${this.saveFiles ? this.saveFiles.length : 0}/${n}…`;
      if (this.savePhase === 2) return `📲 存入相册 第 ${this.saveChunk + 1}/${this.saveGroups} 组（点按继续）`;
      if (this.savePhase === 3) return "✅ 已全部存入相册";
      return `📲 保存到相册（${n} 张）`;
    },
    cardStyle() {
      if (this.flying === 1)
        return { transform: "translateX(-130%) rotate(-16deg)", opacity: 0, transition: "transform .3s ease-in, opacity .3s" };
      if (this.flying === 2)
        return { transform: "translateX(130%) rotate(16deg)", opacity: 0, transition: "transform .3s ease-in, opacity .3s" };
      const rot = this.dx / 22;
      return { transform: `translateX(${this.dx}px) rotate(${rot}deg)`, transition: this.dragging ? "none" : "transform .2s" };
    },
    galDays() {
      const days = [];
      const map = new Map();
      for (const c of this.galItems) {
        const k = dayKey(c.taken_at);
        if (!map.has(k)) {
          let label = "时间未知";
          if (k !== "unknown") {
            const d = new Date(k + "T00:00:00Z");
            label = `${d.getUTCMonth() + 1}月${d.getUTCDate()}日 ${weekdayCn[d.getUTCDay()]}`;
          }
          const grp = { key: k, label, items: [] };
          map.set(k, grp); days.push(grp);
        }
        map.get(k).items.push(c);
      }
      return days;
    },
    fallbackThumb() { return "/static/icons/ph.png"; },
  },
  methods: {
    rawLike(c) { return RAW_EXTS.has((c.ext || "").toLowerCase()); },
    thumbFail(c) { c.has_thumb = 0; },
    fmtTime,

    /* ---------- 加入 ---------- */
    async doJoin() {
      this.joinErr = "";
      if (!this.joinName) { this.joinErr = "先给自己起个名字"; return; }
      this.joining = true;
      try {
        await $api("/api/join", { method: "POST", body: { name: this.joinName, code: this.joinCode } });
        localStorage.setItem("tt_name", this.joinName);
        await this.afterLogin();
      } catch (e) { this.joinErr = e.message; }
      this.joining = false;
    },
    async afterLogin() {
      this.user = await $api("/api/me");
      this.deal();
      this.pollStatus();
    },
    async reloadMe() {
      this.user = await $api("/api/me");
      this.tab = "me";
    },

    /* ---------- 状态轮询 ---------- */
    pollStatus() {
      const loop = async () => {
        try {
          this.status = await $api("/api/status");
          if (this.status.pending === 0) this.loadPersons._dirty = true;
        } catch (e) { /* 离线时静默 */ }
        setTimeout(loop, 5000);
      };
      loop();
    },

    /* ---------- 滑动选片 ---------- */
    async setDealView(v) {
      this.dealView = v;
      this.viewLabel = { timeline: "时间线", random: "随机", mine: "有我的" }[v] || "时间线";
      await this.deal();
    },
    async deal() {
      const d = await $api(`/api/deal?view=${encodeURIComponent(this.dealView)}`);
      this.batch = d;
      this.cardIdx = 0; this.dx = 0; this.flying = 0;
      this.batchDone = false; this.decidedKeeps = []; this.batchNo = d.batch_no;
      this.batchView = d.view || this.dealView;
      this.savePhase = 0; this.saveFiles = null; this.saveChunk = 0; this.saving = false;
      if (!d.cards.length) toast(this.dealView === "mine" ? "还没有带你的照片，先去「人物」认领脸" : "这个视图看完了");
    },
    ts(e) {
      if (this.flying) return;
      this.dragging = true; this._sx = e.touches[0].clientX; this._sy = e.touches[0].clientY; this.dx = 0;
    },
    tm(e) {
      if (!this.dragging || this.flying) return;
      this.dx = e.touches[0].clientX - this._sx;
    },
    te() {
      if (!this.dragging || this.flying) return;
      this.dragging = false;
      if (this.dx > 90) this.decide("keep");
      else if (this.dx < -90) this.decide("skip");
      else this.dx = 0;
    },
    async decide(action) {
      const c = this.curCard;
      if (!c || this.flying) return;
      this.flying = action === "keep" ? 2 : 1;
      try { await $api("/api/decide", { method: "POST", body: { asset_id: c.id, action, batch_no: this.batchNo, view: this.batchView } }); }
      catch (e) { toast("决策没存上：" + e.message); }
      if (action === "keep") this.decidedKeeps.push(c);
    },
    onFlyEnd() {
      if (!this.flying) return;
      this.flying = 0; this.dx = 0;
      if (this.cardIdx + 1 >= this.batch.cards.length) this.batchDone = true;
      else this.cardIdx++;
    },
    async nextBatch() { await this.deal(); },

    /* ---------- 保存到相册 ---------- */
    async fetchFile(c) {
      const r = await fetch(`/api/asset/${c.id}/raw`);
      if (!r.ok) throw new Error("原图拉取失败");
      const blob = await r.blob();
      return new File([blob], c.orig_name || `tuantu_${c.id}.${c.ext}`,
        { type: blob.type || "application/octet-stream" });
    },
    async onSaveBtn() {
      if (this.savePhase === 0) await this.prepareSave();
      else if (this.savePhase === 2) await this.shareNextChunk();
    },
    async prepareSave() {
      /* 第一步：把原图取到本地（这一步消耗掉点击手势，所以取完再点一次才弹分享） */
      this.savePhase = 1;
      this.saveFiles = [];
      try {
        for (const c of this.keptCards) {
          this.saveFiles.push(await this.fetchFile(c));
        }
        this.saveChunk = 0;
        this.savePhase = 2;
        toast("原图就绪，再点一次开始存入相册", 2500);
      } catch (e) {
        this.savePhase = 0; this.saveFiles = null;
        toast("取原图失败：" + e.message + "，可改用 zip", 4000);
      }
    },
    async shareNextChunk() {
      /* 第二步起：每次点击弹一次系统分享，iPhone 选「存储图像」/安卓选相册 */
      const CHUNK = 10;
      const i = this.saveChunk;
      const part = this.saveFiles.slice(i * CHUNK, (i + 1) * CHUNK);
      if (!part.length) { this.savePhase = 3; return; }
      try {
        await navigator.share({ files: part, title: "团图照片" });
        this.saveChunk = i + 1;
        if ((i + 1) * CHUNK >= this.saveFiles.length) {
          this.savePhase = 3;
          toast("已全部存入相册 🎉", 3000);
        }
      } catch (e) {
        if (e && e.name === "AbortError") toast("已取消，随时可以继续存");
        else toast("分享失败：" + (e.message || e.name), 4000);
      }
    },
    async downloadAllIndividually() {
      /* 无分享能力时的兜底：逐张下载。安卓落在「下载」（相册可见），iOS 落在「文件」 */
      if (this.saving) return;
      this.saving = true;
      for (const c of this.keptCards) {
        triggerDownload(`/api/asset/${c.id}/raw?download=1`,
          c.orig_name || `tuantu_${c.id}.${c.ext}`);
        await sleep(350);
      }
      this.saving = false;
      toast(IS_IOS ? "已下载到「文件 › 下载」：打开文件 → 全选 → 分享 → 存储图像"
                   : "已存到「下载」，相册里直接能看到", 5000);
    },
    async saveOne(c) {
      /* 详情页单张保存 */
      if (this.canShare) {
        if (!this._detailFile || this._detailFileId !== c.id) {
          try { this._detailFile = await this.fetchFile(c); this._detailFileId = c.id; }
          catch (e) { toast("取原图失败：" + e.message); return; }
          if (!this._detailGestureWarned) {
            this._detailGestureWarned = true;
            toast("准备好了，再点一次「保存到相册」", 2500);
            return;
          }
        }
        try {
          await navigator.share({ files: [this._detailFile] });
          return;
        } catch (e) {
          if (e && e.name === "AbortError") return;
          /* 分享失败退回下载 */
        }
      }
      triggerDownload(`/api/asset/${c.id}/raw?download=1`,
        c.orig_name || `tuantu_${c.id}.${c.ext}`);
      if (IS_IOS && !this.canShare) toast("已下载到「文件 › 下载」", 3500);
    },

    async downloadBatch() {
      toast("打包中，稍等…", 5000);
      try {
        const r = await fetch(`/api/batch/${this.batchNo}/download?view=${encodeURIComponent(this.batchView)}`);
        if (!r.ok) throw new Error(await r.json().then(j => j.detail || "失败"));
        const blob = await r.blob();
        const a = document.createElement("a");
        a.href = URL.createObjectURL(blob);
        a.download = `tuantu_batch${this.batchNo}.zip`;
        document.body.appendChild(a); a.click(); a.remove();
        setTimeout(() => URL.revokeObjectURL(a.href), 30000);
        toast("已开始下载（iOS 请到「文件」里解压）", 4000);
      } catch (e) { toast("下载失败：" + e.message, 4000); }
    },

    /* ---------- 点赞 ---------- */
    async toggleLike(c) {
      const r = await $api("/api/like", { method: "POST", body: { asset_id: c.id } });
      c.liked = r.liked; c.likes = r.likes;
      if (this.detail && this.detail.id === c.id) { this.detail.liked = r.liked; this.detail.likes = r.likes; this.detail.liked_by = undefined; }
    },

    /* ---------- 相册 ---------- */
    async openGallery() {
      this.tab = "gallery";
      if (!this.galLoaded) this.loadGallery();
    },
    async refreshGal() {
      this.galLoaded = false;
      this.openGallery();
      toast("已刷新");
    },
    async setGalView(v) {
      this.galView = v; this.galLoaded = true;
      this.galItems = []; this.galCursor = null; this.galEnd = false;
      this.loadGallery();
    },
    async loadGallery(more = false) {
      if (!more) { this.galCursor = null; this.galEnd = false; }
      const url = `/api/gallery?view=${encodeURIComponent(this.galView)}&limit=90` +
        (this.galCursor ? `&cursor=${this.galCursor}` : "");
      const d = await $api(url);
      if (more) this.galItems.push(...d.items);
      else this.galItems = d.items;
      this.galCursor = d.cursor;
      this.galEnd = d.items.length < 90;
      this.galLoaded = true;
    },
    async openDetail(c) {
      this.detail = await $api(`/api/asset/${c.id}/detail`);
      /* 预取原图，之后「保存到相册」一次点击就能直接弹分享 */
      if (this.canShare) {
        this._detailFileId = c.id; this._detailFile = null;
        try { this._detailFile = await this.fetchFile(c); } catch (e) { this._detailFile = null; }
      }
    },
    viewRaw(c, download = false) {
      const a = document.createElement("a");
      a.href = `/api/asset/${c.id}/raw${download ? "?download=1" : ""}`;
      a.target = download ? "" : "_blank";
      if (download) a.download = c.orig_name || "";
      document.body.appendChild(a); a.click(); a.remove();
    },

    /* ---------- 人物 ---------- */
    async loadPersons() {
      this.tab = "persons";
      this.persons = await $api("/api/persons");
    },
    claimedName(p) {
      if (!p.claimed_by) return "未认领";
      return p.claimed_by_me ? "是我" : `${p.claimed_by} 已认领`;
    },
    async toggleClaim(p) {
      if (p.claimed_by_me) {
        await $api(`/api/persons/${p.id}/unclaim`, { method: "POST" });
        p.claimed_by_me = false; p.claimed_by = null;
        toast("已取消认领");
      } else {
        await $api(`/api/persons/${p.id}/claim`, { method: "POST" });
        p.claimed_by_me = true; p.claimed_by = this.user.name;
        toast("认领成功！「有我的」视图已更新");
      }
      this.user = await $api("/api/me");
    },
    browsePerson(p) {
      this.dealView = `person:${p.id}`;
      this.viewLabel = p.name || "人物" + p.id;
      this.tab = "swipe";
      this.deal();
    },

    /* ---------- 上传 ---------- */
    pickFiles() { this.$refs.fileEl.click(); },
    onFiles(e) {
      const files = [...e.target.files];
      e.target.value = "";
      if (!files.length) return;
      this.uploadFiles(files);
    },
    async uploadFiles(files) {
      this.uploading = true; this.upResult = null;
      this.upQueue = files.map(f => ({ name: f.name, size: f.size, status: "排队中", file: f }));
      const CONCURRENCY = 3;
      let done = 0;
      const worker = async () => {
        while (this.upQueue.some(u => u.status === "排队中")) {
          const u = this.upQueue.find(x => x.status === "排队中");
          if (!u) return;
          u.status = "上传中…";
          try {
            const fd = new FormData();
            fd.append("files", u.file);
            const r = await new Promise((resolve, reject) => {
              const xhr = new XMLHttpRequest();
              xhr.open("POST", "/api/upload");
              xhr.upload.onprogress = (ev) => {
                if (ev.lengthComputable) u.status = `上传中 ${Math.round(ev.loaded / ev.total * 100)}%`;
              };
              xhr.onload = () => xhr.status < 400 ? resolve(JSON.parse(xhr.responseText)) : reject(new Error("上传失败"));
              xhr.onerror = () => reject(new Error("网络中断"));
              xhr.send(fd);
            });
            if (r.accepted.length) u.status = "✅ 已入库";
            else if (r.duplicates.length) u.status = "⏭️ 重复跳过";
            else u.status = "🚫 不支持";
            this.upResult = { accepted: [...(this.upResult?.accepted || []), ...r.accepted],
              duplicates: [...(this.upResult?.duplicates || []), ...r.duplicates],
              rejected: [...(this.upResult?.rejected || []), ...r.rejected] };
          } catch (err) {
            u.status = "❌ " + err.message;
          }
          done++;
          this.upProgress = Math.round(done / this.upQueue.length * 100);
        }
      };
      await Promise.all(Array.from({ length: CONCURRENCY }, worker));
      this.uploading = false;
      toast("上传完成！盒子正在后台分析", 3000);
      this.status = await $api("/api/status").catch(() => this.status);
    },
  },
  mounted() {
    /* 已有会话则直接进入 */
    $api("/api/me").then(u => { this.user = u; this.deal(); this.pollStatus(); }).catch(() => {});
    if ("serviceWorker" in navigator)
      navigator.serviceWorker.register("/static/sw.js").catch(() => {});
    window.addEventListener("resize", () => { this.dx = 0; });
  },
}).mount("#app");
