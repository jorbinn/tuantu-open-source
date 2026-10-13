package dev.tuantu.tuantu_app;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.media.ExifInterface;
import android.media.MediaExtractor;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.media.MediaScannerConnection;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.provider.MediaStore;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Runs on the real device without launching or navigating the production UI. */
public class LivePhotoInstrumentation extends Instrumentation {
    private Bundle arguments;
    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        this.arguments = arguments;
        start();
    }

    @Override public void onStart() {
        Bundle report = new Bundle();
        File source = new File(getTargetContext().getCacheDir(), "orientation-regression.jpg");
        try {
            if (arguments != null && arguments.containsKey("sourceProbe")) {
                Thread worker = Thread.currentThread();
                Thread watchdog = new Thread(() -> {
                    try {
                        for (int check = 0; check < 6; check++) {
                            Thread.sleep(15000);
                            Bundle status = new Bundle();
                            status.putString("stream", "probe stack: " + java.util.Arrays.toString(worker.getStackTrace()) + "\n");
                            sendStatus(0, status);
                        }
                    } catch (InterruptedException ignored) { }
                }, "LiveProbeWatchdog");
                watchdog.setDaemon(true); watchdog.start();
                File dir = arguments.containsKey("probeRoot") ? getTargetContext().getExternalFilesDir(null) :
                    new File(getTargetContext().getExternalFilesDir(null), "live-probe");
                StringBuilder details = new StringBuilder();
                for (String name : arguments.getString("sourceProbe").split(",")) {
                    File external = new File(dir, name);
                    details.append(external).append(" exists=").append(external.exists())
                        .append(" bytes=").append(external.length()).append('\n');
                    File input = new File(getTargetContext().getCacheDir(), "probe-" + name);
                    try (InputStream in = new FileInputStream(external);
                         FileOutputStream out = new FileOutputStream(input)) {
                        byte[] buffer = new byte[32768]; int n;
                        while ((n = in.read(buffer)) != -1) out.write(buffer, 0, n);
                    }
                    MediaExtractor probe = new MediaExtractor();
                    try {
                        probe.setDataSource(input.getPath());
                        details.append(name).append(" tracks=").append(probe.getTrackCount()).append('\n');
                        for (int i = 0; i < probe.getTrackCount(); i++)
                            details.append(probe.getTrackFormat(i)).append('\n');
                    } catch (Exception error) {
                        details.append(name).append(" raw extractor: ").append(error).append('\n');
                    } finally { probe.release(); }
                    File out = new File(dir, name + ".normalized.mp4");
                    details.append("remux=").append(LiveVideoCodec.INSTANCE.remuxForMotionPhoto(
                        input.getPath(), out.getPath())).append('\n');
                    input.delete();
                }
                report.putString("stream", details.toString());
                watchdog.interrupt();
                finish(Activity.RESULT_OK, report);
                return;
            }
            if (arguments != null && arguments.containsKey("galleryApk")) {
                report.putString("stream", GalleryParserProbe.run(
                    arguments.getString("galleryApk"),
                    new File(getTargetContext().getExternalFilesDir(null), "live-probe"),
                    getTargetContext().getClassLoader()));
                finish(Activity.RESULT_OK, report);
                return;
            }
            // Quadrants are asymmetric, so dimension-only checks cannot hide mirroring.
            int[] colors = {Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW};
            int[][] expected = {
                {0, 1, 2, 3}, {1, 0, 3, 2}, {3, 2, 1, 0}, {2, 3, 0, 1},
                {0, 2, 1, 3}, {2, 0, 3, 1}, {3, 1, 2, 0}, {1, 3, 0, 2}
            };
            for (int orientation = 1; orientation <= 8; orientation++) {
                Bitmap raw = Bitmap.createBitmap(120, 80, Bitmap.Config.ARGB_8888);
                for (int y = 0; y < 80; y++) for (int x = 0; x < 120; x++)
                    raw.setPixel(x, y, colors[(y < 40 ? 0 : 2) + (x < 60 ? 0 : 1)]);
                try (FileOutputStream out = new FileOutputStream(source)) {
                    raw.compress(Bitmap.CompressFormat.JPEG, 100, out);
                }
                raw.recycle();
                ExifInterface exif = new ExifInterface(source.getPath());
                exif.setAttribute(ExifInterface.TAG_ORIENTATION, Integer.toString(orientation));
                exif.saveAttributes();
                Bitmap upright = StillImageCodec.INSTANCE.decode(source.getPath());
                if (upright == null) throw new AssertionError("decode " + orientation);
                int w = orientation >= 5 ? 80 : 120;
                int h = orientation >= 5 ? 120 : 80;
                if (upright.getWidth() != w || upright.getHeight() != h)
                    throw new AssertionError("dimensions " + orientation);
                for (int q = 0; q < 4; q++) {
                    int actual = upright.getPixel(q % 2 == 0 ? w / 4 : w * 3 / 4,
                        q < 2 ? h / 4 : h * 3 / 4);
                    int desired = colors[expected[orientation - 1][q]];
                    if (Math.abs(Color.red(actual) - Color.red(desired)) > 20 ||
                        Math.abs(Color.green(actual) - Color.green(desired)) > 20 ||
                        Math.abs(Color.blue(actual) - Color.blue(desired)) > 20)
                        throw new AssertionError("mirror/rotation " + orientation + " quadrant " + q);
                }
                upright.recycle();
            }
            verifyQuickTimeRemux();
            verifyMirroredLpcm();
            report.putString("stream", "PASS: EXIF 1-8, audible PCM/AAC, QuickTime v2 LPCM, mirrored video pixels and Live indexing\n");
            finish(Activity.RESULT_OK, report);
        } catch (Throwable error) {
            report.putString("stream", "FAIL: " + error + "\n");
            finish(Activity.RESULT_CANCELED, report);
        } finally {
            source.delete();
        }
    }

    private void verifyQuickTimeRemux() throws Exception {
        File source = new File(getTargetContext().getCacheDir(), "iphone-live-fixture.mov");
        File output = new File(getTargetContext().getCacheDir(), "iphone-live-normalized.mp4");
        try {
            try (InputStream in = getContext().getAssets().open("iphone_live.mov");
                 FileOutputStream out = new FileOutputStream(source)) {
                byte[] buffer = new byte[16 * 1024];
                int read;
                while ((read = in.read(buffer)) >= 0) out.write(buffer, 0, read);
            }
            if (!LiveVideoCodec.INSTANCE.remuxForMotionPhoto(source.getPath(), output.getPath()))
                throw new AssertionError("QuickTime remux failed");
            byte[] header = new byte[12];
            try (FileInputStream in = new FileInputStream(output)) {
                if (in.read(header) != header.length) throw new AssertionError("short MP4 output");
            }
            if (!"ftyp".equals(new String(header, 4, 4, StandardCharsets.US_ASCII)))
                throw new AssertionError("missing ftyp");
            if ("qt  ".equals(new String(header, 8, 4, StandardCharsets.US_ASCII)))
                throw new AssertionError("output remained QuickTime");

            MediaExtractor extractor = new MediaExtractor();
            boolean hasVideo = false;
            boolean hasAudio = false;
            try {
                extractor.setDataSource(output.getPath());
                for (int i = 0; i < extractor.getTrackCount(); i++) {
                    MediaFormat format = extractor.getTrackFormat(i);
                    String mime = format.getString(MediaFormat.KEY_MIME);
                    if (mime != null && mime.startsWith("video/")) hasVideo = true;
                    if (MediaFormat.MIMETYPE_AUDIO_AAC.equals(mime)) hasAudio = true;
                    if (mime != null && mime.startsWith("audio/") &&
                        !MediaFormat.MIMETYPE_AUDIO_AAC.equals(mime))
                        throw new AssertionError("unsupported audio survived: " + mime);
                }
            } finally {
                extractor.release();
            }
            if (!hasVideo) throw new AssertionError("normalized MP4 has no video");
            if (!hasAudio) throw new AssertionError("PCM audio was silently dropped");
            verifyAudible(output);

            MediaMetadataRetriever retriever = new MediaMetadataRetriever();
            try {
                retriever.setDataSource(output.getPath());
                Bitmap frame = retriever.getFrameAtTime(0);
                if (frame == null) throw new AssertionError("normalized MP4 is not decodable");
                frame.recycle();
            } finally {
                retriever.release();
            }
            verifyOplusIndexing(output);
        } finally {
            source.delete();
            output.delete();
        }
    }

    private void verifyOplusIndexing(File normalizedVideo) throws Exception {
        File still = new File(getTargetContext().getCacheDir(), "oplus-live-still.jpg");
        File motion = new File(getTargetContext().getCacheDir(), "oplus-live-motion.jpg");
        Uri uri = null;
        try {
            Bitmap bitmap = Bitmap.createBitmap(96, 64, Bitmap.Config.ARGB_8888);
            bitmap.eraseColor(Color.MAGENTA);
            try (FileOutputStream out = new FileOutputStream(still)) {
                bitmap.compress(Bitmap.CompressFormat.JPEG, 95, out);
            }
            bitmap.recycle();
            LiveVideoCodec.INSTANCE.stampStillOwner(still.getPath(), "oplus");
            String tag = new ExifInterface(still.getPath())
                .getAttribute(ExifInterface.TAG_USER_COMMENT);
            if (!"oplus_10485792".equals(tag) ||
                    (Long.parseLong(tag.substring(6)) & 0x800000L) == 0)
                throw new AssertionError("OPlus EXIF numeric Live bit missing");

            byte[] jpeg = readAll(still);
            byte[] video = readAll(normalizedVideo);
            String xmp = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" " +
                "x:xmptk=\"Adobe XMP Core 5.1.0-jc003\"><rdf:RDF " +
                "xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" +
                "<rdf:Description rdf:about=\"\" " +
                "xmlns:GCamera=\"http://ns.google.com/photos/1.0/camera/\" " +
                "xmlns:OpCamera=\"http://ns.oplus.com/photos/1.0/camera/\" " +
                "xmlns:Container=\"http://ns.google.com/photos/1.0/container/\" " +
                "xmlns:Item=\"http://ns.google.com/photos/1.0/container/item/\" " +
                "GCamera:MotionPhoto=\"1\" GCamera:MotionPhotoVersion=\"1\" " +
                "GCamera:MotionPhotoPresentationTimestampUs=\"400000\" " +
                "OpCamera:MotionPhotoPrimaryPresentationTimestampUs=\"400000\" " +
                "OpCamera:MotionPhotoVideoStart=\"0\" " +
                "OpCamera:MotionPhotoVideoEnd=\"0\" " +
                "OpCamera:MotionPhotoOwner=\"oplus\" " +
                "OpCamera:OLivePhotoVersion=\"2\" " +
                "OpCamera:VideoLength=\"" + video.length + "\">" +
                "<Container:Directory><rdf:Seq>" +
                "<rdf:li rdf:parseType=\"Resource\"><Container:Item " +
                "Item:Mime=\"image/jpeg\" Item:Semantic=\"Primary\" " +
                "Item:Length=\"0\" Item:Padding=\"0\"/></rdf:li>" +
                "<rdf:li rdf:parseType=\"Resource\"><Container:Item " +
                "Item:Mime=\"video/mp4\" Item:Semantic=\"MotionPhoto\" " +
                "Item:Length=\"" + video.length + "\"/></rdf:li>" +
                "</rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>";
            byte[] ns = "http://ns.adobe.com/xap/1.0/\0".getBytes(StandardCharsets.UTF_8);
            byte[] xml = xmp.getBytes(StandardCharsets.UTF_8);
            int app1Length = ns.length + xml.length + 2;
            try (ByteArrayOutputStream joined = new ByteArrayOutputStream(
                    jpeg.length + video.length + app1Length + 4)) {
                joined.write(jpeg, 0, 2);
                joined.write(0xff); joined.write(0xe1);
                joined.write((app1Length >> 8) & 0xff);
                joined.write(app1Length & 0xff);
                joined.write(ns); joined.write(xml);
                joined.write(jpeg, 2, jpeg.length - 2);
                joined.write(video);
                try (FileOutputStream out = new FileOutputStream(motion)) {
                    joined.writeTo(out);
                }
            }

            ContentResolver resolver = getTargetContext().getContentResolver();
            ContentValues values = new ContentValues();
            values.put(MediaStore.Images.Media.DISPLAY_NAME,
                "TUANTU_OPLUS_REGRESSION_" + System.currentTimeMillis() + ".jpg");
            values.put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg");
            values.put(MediaStore.Images.Media.RELATIVE_PATH,
                Environment.DIRECTORY_DCIM + "/Camera");
            values.put(MediaStore.Images.Media.IS_PENDING, 1);
            uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values);
            if (uri == null) throw new AssertionError("MediaStore insert failed");
            try (InputStream in = new FileInputStream(motion);
                 java.io.OutputStream out = resolver.openOutputStream(uri, "w")) {
                if (out == null) throw new AssertionError("MediaStore output missing");
                byte[] buffer = new byte[32 * 1024];
                int read;
                while ((read = in.read(buffer)) >= 0) out.write(buffer, 0, read);
            }
            values.clear();
            values.put(MediaStore.Images.Media.IS_PENDING, 0);
            resolver.update(uri, values, null, null);

            String path;
            try (android.database.Cursor cursor = resolver.query(uri,
                    new String[]{MediaStore.MediaColumns.DATA}, null, null, null)) {
                if (cursor == null || !cursor.moveToFirst())
                    throw new AssertionError("MediaStore row missing");
                path = cursor.getString(0);
            }
            CountDownLatch scan = new CountDownLatch(1);
            MediaScannerConnection.scanFile(getTargetContext(), new String[]{path},
                new String[]{"image/jpeg"}, (p, scannedUri) -> scan.countDown());
            scan.await(5, TimeUnit.SECONDS);

            Boolean recognized = null;
            for (int attempt = 0; attempt < 10; attempt++) {
                recognized = LiveVideoCodec.INSTANCE.galleryRecognizesMotionPhoto(
                    getTargetContext(), path, "oplus");
                if (Boolean.TRUE.equals(recognized)) break;
                Thread.sleep(250);
            }
            if (recognized != null && !recognized)
                throw new AssertionError("OPlus MediaProvider rejected tagged Motion Photo");
        } finally {
            if (uri != null) getTargetContext().getContentResolver().delete(uri, null, null);
            still.delete();
            motion.delete();
        }
    }

    private void verifyMirroredLpcm() throws Exception {
        File source = new File(getTargetContext().getCacheDir(), "lpcm-mirrored.mov");
        File output = new File(getTargetContext().getCacheDir(), "lpcm-upright.mp4");
        File baseline = new File(getTargetContext().getCacheDir(), "upright-reference.mov");
        try {
            for (String name : new String[]{"iphone_lpcm_mirror.mov", "iphone_transform.mov"}) {
                try (InputStream in = getContext().getAssets().open(name);
                     FileOutputStream out = new FileOutputStream(name.contains("mirror") ? source : baseline)) {
                    byte[] buffer = new byte[16384]; int n;
                    while ((n = in.read(buffer)) != -1) out.write(buffer, 0, n);
                }
            }
            // Unsupported v2 PCM must fail, not masquerade as a silent success.
            byte[] fixture = readAll(source);
            int lpcm = -1;
            for (int p = 4; p + 68 < fixture.length; p++) {
                if (fixture[p] == 'l' && fixture[p+1] == 'p' && fixture[p+2] == 'c' && fixture[p+3] == 'm') {
                    lpcm = p; break;
                }
            }
            if (lpcm < 0) throw new AssertionError("fixture LPCM missing");
            try (java.io.RandomAccessFile patch = new java.io.RandomAccessFile(source, "rw")) {
                patch.seek(lpcm + 56); patch.writeInt(13); // float, not signed 16-bit
            }
            if (LiveVideoCodec.INSTANCE.remuxForMotionPhoto(source.getPath(), output.getPath()) || output.exists())
                throw new AssertionError("Unsupported audio reported success");
            try (FileOutputStream restore = new FileOutputStream(source)) { restore.write(fixture); }
            if (!LiveVideoCodec.INSTANCE.remuxForMotionPhoto(source.getPath(), output.getPath()))
                throw new AssertionError("QuickTime v2 LPCM / reflection conversion failed");
            if (!java.util.Arrays.equals(fixture, readAll(source)))
                throw new AssertionError("Original MOV was modified");
            verifyAudible(output);
            MediaMetadataRetriever original = new MediaMetadataRetriever();
            MediaMetadataRetriever result = new MediaMetadataRetriever();
            try {
                original.setDataSource(baseline.getPath());
                result.setDataSource(output.getPath());
                Bitmap before = original.getFrameAtTime(0);
                Bitmap after = result.getFrameAtTime(0);
                if (before == null || after == null || after.getWidth() != before.getHeight() ||
                    after.getHeight() != before.getWidth()) throw new AssertionError("Reflection dimensions");
                long error = 0; int count = 0;
                for (int y = 8; y < before.getHeight() - 8; y += 4)
                    for (int x = 8; x < before.getWidth() - 8; x += 4) {
                        int a = before.getPixel(x,y);
                        int b = after.getPixel(before.getHeight()-1-y, before.getWidth()-1-x);
                        error += Math.abs(Color.red(a)-Color.red(b)) +
                            Math.abs(Color.green(a)-Color.green(b)) + Math.abs(Color.blue(a)-Color.blue(b));
                        count += 3;
                    }
                before.recycle(); after.recycle();
                if (error / (double)count > 20) throw new AssertionError("Wrong mirrored pixels: " + error/(double)count);
                if (!"0".equals(result.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)))
                    throw new AssertionError("Baked transform must have identity rotation");
            } finally { original.release(); result.release(); }
        } finally { source.delete(); output.delete(); baseline.delete(); }
    }

    private void verifyAudible(File file) throws Exception {
        MediaExtractor input = new MediaExtractor();
        MediaCodec decoder = null;
        try {
            input.setDataSource(file.getPath());
            MediaFormat audio = null;
            for (int i = 0; i < input.getTrackCount(); i++) {
                MediaFormat f = input.getTrackFormat(i);
                if (MediaFormat.MIMETYPE_AUDIO_AAC.equals(f.getString(MediaFormat.KEY_MIME))) {
                    audio = f; input.selectTrack(i); break;
                }
            }
            if (audio == null) throw new AssertionError("AAC track missing");
            decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC);
            decoder.configure(audio, null, null, 0); decoder.start();
            boolean end = false, done = false;
            long samples = 0, nonzero = 0;
            long deadline = System.nanoTime() + 15_000_000_000L;
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            while (!done && System.nanoTime() < deadline) {
                if (!end) {
                    int index = decoder.dequeueInputBuffer(1000);
                    if (index >= 0) {
                        java.nio.ByteBuffer b = decoder.getInputBuffer(index); b.clear();
                        int size = input.readSampleData(b, 0);
                        end = size < 0;
                        decoder.queueInputBuffer(index, 0, end ? 0 : size,
                            end ? 0 : input.getSampleTime(), end ? MediaCodec.BUFFER_FLAG_END_OF_STREAM : 0);
                        if (!end) input.advance();
                    }
                }
                int index = decoder.dequeueOutputBuffer(info, 1000);
                if (index >= 0) {
                    java.nio.ByteBuffer b = decoder.getOutputBuffer(index).order(java.nio.ByteOrder.LITTLE_ENDIAN);
                    for (int p = info.offset; p + 1 < info.offset + info.size; p += 2) {
                        if (Math.abs((int)b.getShort(p)) > 16) nonzero++;
                        samples++;
                    }
                    done = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
                    decoder.releaseOutputBuffer(index, false);
                }
            }
            if (!done || samples < 30000 || nonzero < samples/10)
                throw new AssertionError("AAC not audible/complete: " + samples + "/" + nonzero);
        } finally {
            input.release();
            if (decoder != null) { try { decoder.stop(); } finally { decoder.release(); } }
        }
    }

    private static byte[] readAll(File file) throws Exception {
        try (FileInputStream in = new FileInputStream(file);
             ByteArrayOutputStream out = new ByteArrayOutputStream((int) file.length())) {
            byte[] buffer = new byte[32 * 1024];
            int read;
            while ((read = in.read(buffer)) >= 0) out.write(buffer, 0, read);
            return out.toByteArray();
        }
    }

}
