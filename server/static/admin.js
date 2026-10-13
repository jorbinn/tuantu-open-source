/* 团图管理台逻辑 */
"use strict";
Vue.createApp({
  data() {
    return { authed: false, code: "", err: "", ov: null, persons: [] };
  },
  methods: {
    fmtMB(b) { return (b / 1048576 / 1024).toFixed(2) + " GB"; },
    hdr() { return { "X-Admin-Token": localStorage.getItem("tt_admin") || "", "Content-Type": "application/json" }; },
    async api(url, opts = {}) {
      const r = await fetch(url, { ...opts, headers: this.hdr(),
        body: opts.body ? JSON.stringify(opts.body) : undefined });
      if (r.status === 401) { this.authed = false; throw new Error("口令失效"); }
      const d = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(d.detail || "请求失败");
      return d;
    },
    toast(msg) {
      const t = document.getElementById("toast");
      t.textContent = msg; t.classList.add("show");
      clearTimeout(t._tm); t._tm = setTimeout(() => t.classList.remove("show"), 2200);
    },
    async login() {
      localStorage.setItem("tt_admin", this.code.trim());
      try { await this.load(); this.authed = true; this.err = ""; }
      catch (e) { this.err = "口令不对"; }
    },
    async load() {
      this.ov = await this.api("/api/admin/overview");
      this.persons = (await this.api("/api/admin/persons")).map(p => ({ ...p, _name: p.name || "", _mergeTo: "" }));
    },
    async rename(p) {
      await this.api(`/api/admin/persons/${p.id}/rename`, { method: "POST", body: { name: p._name } });
      this.toast("已保存名字");
    },
    async merge(p) {
      if (!confirm(`确定把「${p.name || "#" + p.id}」并入「#${p._mergeTo}」？`)) return;
      await this.api(`/api/admin/persons/${p.id}/merge/${p._mergeTo}`, { method: "POST" });
      this.toast("已合并"); this.load();
    },
    async delPerson(p) {
      if (!confirm(`删掉人物组「${p.name || "#" + p.id}」？照片不受影响，只是这些脸不再归组。`)) return;
      await this.api(`/api/admin/persons/${p.id}/delete`, { method: "POST" });
      this.load();
    },
    async recluster() {
      if (!confirm("全量重聚类可能要跑几分钟，确定？")) return;
      this.toast("聚类中…");
      const r = await this.api("/api/admin/recluster", { method: "POST" });
      this.toast(`完成，共 ${r.persons} 组`); this.load();
    },
    exportAll() {
      const a = document.createElement("a");
      a.href = "/api/admin/export";
      document.body.appendChild(a); a.click(); a.remove();
      this.toast("开始打包导出，照片多的话要等一会儿");
    },
    async wipe() {
      if (!confirm("真的要清空相册？所有照片/视频/点赞记录都会删除，无法恢复！")) return;
      if (!confirm("再次确认：清空后连原片都没有了，确定备份过了？")) return;
      await this.api("/api/admin/wipe", { method: "POST" });
      this.toast("已清空"); this.load();
    },
  },
  mounted() {
    if (localStorage.getItem("tt_admin")) this.login();
  },
}).mount("#app");
