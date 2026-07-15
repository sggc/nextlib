/*
 * 修改后的 FfmpegLibrary.java
 *
 * 替换 nextlib/media3ext/src/main/java/io/github/anilbeesetti/nextlib/media3ext/ffdecoder/FfmpegLibrary.java
 *
 * 新增 CAVS / AVS2 / AVS3 视频 codec 映射:
 *   "video/cavs" -> "cavs"        (FFmpeg 内置 CAVS 解码器)
 *   "video/avs2" -> "libdavs2"    (外部 libdavs2 库)
 *   "video/avs3" -> "avs3"        (FFmpeg 内置 AVS3 解码器, 需要 CAVS patch)
 */
package io.github.anilbeesetti.nextlib.media3ext.ffdecoder;

import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.MediaLibraryInfo;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.LibraryLoader;
import androidx.media3.common.util.Log;
import androidx.media3.common.util.UnstableApi;
import org.checkerframework.checker.nullness.qual.MonotonicNonNull;

/** Configures and queries the underlying native library. */
@UnstableApi
public final class FfmpegLibrary {

  static {
    MediaLibraryInfo.registerModule("media3.decoder.ffmpeg");
  }

  private static final String TAG = "FfmpegLibrary";

  private static final LibraryLoader LOADER =
      new LibraryLoader("media3ext") {
        @Override
        protected void loadLibrary(String name) {
          System.loadLibrary(name);
        }
      };

  private static @MonotonicNonNull String version;
  private static int inputBufferPaddingSize = C.LENGTH_UNSET;

  private FfmpegLibrary() {}

  public static void setLibraries(String... libraries) {
    LOADER.setLibraries(libraries);
  }

  public static boolean isAvailable() {
    return LOADER.isAvailable();
  }

  @Nullable
  public static String getVersion() {
    if (!isAvailable()) {
      return null;
    }
    if (version == null) {
      version = ffmpegGetVersion();
    }
    return version;
  }

  public static int getInputBufferPaddingSize() {
    if (!isAvailable()) {
      return C.LENGTH_UNSET;
    }
    if (inputBufferPaddingSize == C.LENGTH_UNSET) {
      inputBufferPaddingSize = ffmpegGetInputBufferPaddingSize();
    }
    return inputBufferPaddingSize;
  }

  public static boolean supportsFormat(String mimeType) {
    if (!isAvailable()) {
      return false;
    }
    @Nullable String codecName = getCodecName(mimeType);
    if (codecName == null) {
      return false;
    }
    if (!ffmpegHasDecoder(codecName)) {
      Log.w(TAG, "No " + codecName + " decoder available. Check the FFmpeg build configuration.");
      return false;
    }
    return true;
  }

  @Nullable
  /* package */ static String getCodecName(String mimeType) {
    return switch (mimeType) {
      // Audio codecs
      case MimeTypes.AUDIO_AAC -> "aac";
      case MimeTypes.AUDIO_MPEG, MimeTypes.AUDIO_MPEG_L1, MimeTypes.AUDIO_MPEG_L2 -> "mp3";
      case MimeTypes.AUDIO_AC3 -> "ac3";
      case MimeTypes.AUDIO_E_AC3, MimeTypes.AUDIO_E_AC3_JOC -> "eac3";
      case MimeTypes.AUDIO_TRUEHD -> "truehd";
      case MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_HD -> "dca";
      case MimeTypes.AUDIO_VORBIS -> "vorbis";
      case MimeTypes.AUDIO_OPUS -> "opus";
      case MimeTypes.AUDIO_AMR_NB -> "amrnb";
      case MimeTypes.AUDIO_AMR_WB -> "amrwb";
      case MimeTypes.AUDIO_FLAC -> "flac";
      case MimeTypes.AUDIO_ALAC -> "alac";
      case MimeTypes.AUDIO_MLAW -> "pcm_mulaw";
      case MimeTypes.AUDIO_ALAW -> "pcm_alaw";

      // Video codecs
      case MimeTypes.VIDEO_H264 -> "h264";
      case MimeTypes.VIDEO_H265 -> "hevc";
      case MimeTypes.VIDEO_MPEG -> "mpegvideo";
      case MimeTypes.VIDEO_MPEG2 -> "mpeg2video";
      case MimeTypes.VIDEO_VP8 -> "libvpx";
      case MimeTypes.VIDEO_VP9 -> "libvpx-vp9";

      // === CAVS / AVS2 / AVS3 视频编解码器 (自定义添加) ===
      case "video/cavs" -> "cavs";
      case "video/avs2" -> "libdavs2";
      case "video/avs3" -> "avs3";

      default -> null;
    };
  }

  private static native String ffmpegGetVersion();

  private static native int ffmpegGetInputBufferPaddingSize();

  private static native boolean ffmpegHasDecoder(String codecName);
}
