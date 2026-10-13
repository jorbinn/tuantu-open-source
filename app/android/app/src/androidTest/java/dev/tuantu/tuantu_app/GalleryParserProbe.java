package dev.tuantu.tuantu_app;

import dalvik.system.PathClassLoader;
import java.io.File;
import java.io.FileInputStream;
import java.util.Arrays;

/** Optional, read-only comparison using the installed RMX5010 Gallery decoder.
 * Obfuscated names belong to that diagnostic APK version, never production.
 */
public final class GalleryParserProbe {
    public static String run(String apk, File directory, ClassLoader parent) throws Exception {
        // App and Gallery both contain R8 classes named a/b/e; only framework
        // classes may be shared, otherwise a different app's helper is called.
        ClassLoader loader = new PathClassLoader(apk, parent.getParent());
        Class<?> sourceType = loader.loadClass("com.oplus.aiunit.vision.rt5");
        Class<?> fileType = loader.loadClass("com.oplus.aiunit.vision.ql8");
        Class<?> decoderType = loader.loadClass("com.oplus.aiunit.vision.sie");
        File[] files = directory.listFiles((dir, name) -> name.endsWith(".jpg"));
        if (files == null || files.length == 0) throw new AssertionError("No probe fixtures");
        Arrays.sort(files);
        StringBuilder report = new StringBuilder();
        for (File file : files) {
            report.append(file.getName()).append(": ");
            try {
                Object source = fileType.getConstructor(String.class).newInstance(file.getPath());
                Object decoder = decoderType.getConstructor(sourceType).newInstance(source);
                Object info = decoderType.getMethod("b").invoke(decoder);
                if (info == null) {
                    report.append("Gallery rejected container\n");
                    continue;
                }
                Object video = info.getClass().getField("h").get(info);
                long offset = video.getClass().getField("b").getLong(video);
                long length = video.getClass().getField("c").getLong(video);
                long mainLength = video.getClass().getField("d").getLong(video);
                report.append("offset=").append(offset).append(" length=").append(length)
                    .append(" mainLength=").append(mainLength);
                try (FileInputStream in = new FileInputStream(file)) {
                    in.getChannel().position(offset);
                    byte[] header = new byte[12];
                    int read = in.read(header);
                    report.append(" pointsToFtyp=").append(read == 12 &&
                        header[4] == 'f' && header[5] == 't' && header[6] == 'y' && header[7] == 'p');
                }
                report.append("\n");
            } catch (Throwable error) {
                report.append("ERROR ").append(error).append(" cause=")
                    .append(error.getCause()).append("\n");
            }
        }
        return report.toString();
    }
}
