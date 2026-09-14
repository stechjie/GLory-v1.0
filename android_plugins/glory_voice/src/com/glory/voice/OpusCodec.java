package com.glory.voice;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Build;
import android.os.SystemClock;
import android.util.Log;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.ShortBuffer;
import java.util.ArrayList;
import java.util.List;

/**
 * Opus 编解码，走系统 MediaCodec（docs/聊天系统设计.md 第九节）。
 *
 * 支持范围（developer.android.com/media/platform/supported-formats）：**编码安卓 10 起、解码安卓 5 起**。
 * 所以安卓 9 及以下的手机只发 ADPCM，但照样听得见别人发的 Opus。
 *
 * ⚠️ 这个类没法在开发机上测（没有安卓设备）。所以：
 *   - 开语音时先在后台跑一次 selfTest()（编 25 帧、解回来、看有没有声音），不过就一直用 ADPCM；
 *   - 运行中任何一步抛异常，调用方把编码器换回 ADPCM；
 *   - 解码器建不起来，那个队友发来的 Opus 包记成坏包，不崩。
 *
 * 实现要点（对着 AOSP 源码核过）：
 *   - 软件编码器 C2SoftOpusEnc 支持 16 kHz 单声道输入、按 20 毫秒凑帧，每个输出缓冲是一个 Opus 包；
 *     第一个输出是 codec config（CSD），跳过。默认码率 128 kbps、复杂度 10，这里改成 24 kbps、复杂度 5。
 *   - 软件解码器 C2SoftOpusDec 固定输出 48 kHz，并且要求前三个输入是 OpusHead、编码延迟、seek pre-roll
 *     （由 csd-0/1/2 送进去），所以解出来要重采样回 16 kHz（Resampler）。
 */
final class OpusCodec {
    private static final String TAG = "GloryVoice";
    static final String MIME = "audio/opus";
    static final int BITRATE = 24000;
    static final int COMPLEXITY = 5;
    /** 编码器输入缓冲最多等 5 毫秒（采集线程里等得起）。 */
    private static final long INPUT_TIMEOUT_US = 5000;
    /** libopus 编码器的前瞻 6.5 毫秒，48 kHz 下是 312 个采样。 */
    private static final int PRE_SKIP_48K = 312;
    private static final long SEEK_PREROLL_NS = 80000000L;
    private static final long FRAME_US = 20000;

    private OpusCodec() {
    }

    static boolean encoderSupported() {
        return Build.VERSION.SDK_INT >= 29;
    }

    static final class Encoder implements FrameCodec.Encoder {
        private final MediaCodec codec;
        private final MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        private long ptsUs;

        private Encoder(MediaCodec codec) {
            this.codec = codec;
        }

        /** 建不起来返回 null（安卓 9 及以下、或者这台手机没有 Opus 编码器）。 */
        static Encoder create() {
            if (!encoderSupported()) {
                return null;
            }
            MediaCodec codec = null;
            try {
                codec = MediaCodec.createEncoderByType(MIME);
                MediaFormat format = MediaFormat.createAudioFormat(MIME, AdpcmCodec.SAMPLE_RATE, 1);
                format.setInteger(MediaFormat.KEY_BIT_RATE, BITRATE);
                format.setInteger(MediaFormat.KEY_COMPLEXITY, COMPLEXITY);
                format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, AdpcmCodec.FRAME_SAMPLES * 2 * 4);
                codec.configure(format, null, null, 0);
                codec.start();
                return new Encoder(codec);
            } catch (Exception e) {
                Log.w(TAG, "opus encoder unavailable", e);
                releaseQuietly(codec);
                return null;
            }
        }

        @Override
        public int codecId() {
            return FrameCodec.OPUS;
        }

        @Override
        public void encode(short[] pcm, FrameCodec.FrameSink sink) {
            int index = codec.dequeueInputBuffer(INPUT_TIMEOUT_US);
            if (index >= 0) {
                ByteBuffer input = codec.getInputBuffer(index);
                if (input != null) {
                    input.clear();
                    input.order(ByteOrder.LITTLE_ENDIAN);
                    input.asShortBuffer().put(pcm, 0, AdpcmCodec.FRAME_SAMPLES);
                    codec.queueInputBuffer(index, 0, AdpcmCodec.FRAME_SAMPLES * 2, ptsUs, 0);
                    ptsUs += FRAME_US;
                }
            }
            drain(sink, 0);
        }

        /** 把编码器里已经编好的包取出来。timeoutUs = 0 表示不等。 */
        void drain(FrameCodec.FrameSink sink, long timeoutUs) {
            long timeout = timeoutUs;
            while (true) {
                int out = codec.dequeueOutputBuffer(info, timeout);
                timeout = 0;
                if (out == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    return;
                }
                if (out < 0) {
                    continue; // 输出格式变了 / 输出缓冲换了：不影响取包
                }
                ByteBuffer buffer = codec.getOutputBuffer(out);
                boolean config = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
                if (!config && info.size > 0 && buffer != null) {
                    byte[] data = new byte[info.size];
                    buffer.position(info.offset);
                    buffer.limit(info.offset + info.size);
                    buffer.get(data);
                    sink.onFrame(data);
                }
                codec.releaseOutputBuffer(out, false);
            }
        }

        @Override
        public void reset() {
            // Opus 自己处理得了两段话之间的空白，不用重置（flush 反而要重新等一拍输出）。
        }

        @Override
        public void release() {
            releaseQuietly(codec);
        }
    }

    static final class Decoder implements FrameCodec.Decoder {
        private final MediaCodec codec;
        private final MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        private int outputRate = 48000;
        private int outputChannels = 1;
        private Resampler resampler;
        private short[] raw = new short[4096];
        private short[] mono = new short[4096];
        private short[] resampled = new short[2048];
        private long ptsUs;

        private Decoder(MediaCodec codec) {
            this.codec = codec;
        }

        static Decoder create() {
            MediaCodec codec = null;
            try {
                codec = MediaCodec.createDecoderByType(MIME);
                MediaFormat format = MediaFormat.createAudioFormat(MIME, 48000, 1);
                format.setByteBuffer("csd-0", opusHead());
                format.setByteBuffer("csd-1", nanoseconds(PRE_SKIP_48K * 1000000000L / 48000));
                format.setByteBuffer("csd-2", nanoseconds(SEEK_PREROLL_NS));
                codec.configure(format, null, null, 0);
                codec.start();
                return new Decoder(codec);
            } catch (Exception e) {
                Log.w(TAG, "opus decoder unavailable", e);
                releaseQuietly(codec);
                return null;
            }
        }

        @Override
        public boolean decode(byte[] data, int offset, int length, FrameCodec.PcmSink sink) {
            try {
                drain(sink, 0);
                int index = codec.dequeueInputBuffer(0);
                if (index < 0) {
                    return false;
                }
                ByteBuffer input = codec.getInputBuffer(index);
                if (input == null) {
                    return false;
                }
                input.clear();
                input.put(data, offset, length);
                codec.queueInputBuffer(index, 0, length, ptsUs, 0);
                ptsUs += FRAME_US;
                drain(sink, 0);
                return true;
            } catch (Exception e) {
                Log.w(TAG, "opus decode failed", e);
                return false;
            }
        }

        @Override
        public void drain(FrameCodec.PcmSink sink) {
            try {
                drain(sink, 0);
            } catch (Exception e) {
                Log.w(TAG, "opus drain failed", e);
            }
        }

        void drain(FrameCodec.PcmSink sink, long timeoutUs) {
            long timeout = timeoutUs;
            while (true) {
                int out = codec.dequeueOutputBuffer(info, timeout);
                timeout = 0;
                if (out == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    return;
                }
                if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat format = codec.getOutputFormat();
                    if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                        outputRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE);
                    }
                    if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                        outputChannels = Math.max(1, format.getInteger(MediaFormat.KEY_CHANNEL_COUNT));
                    }
                    resampler = null;
                    continue;
                }
                if (out < 0) {
                    continue;
                }
                ByteBuffer buffer = codec.getOutputBuffer(out);
                if (buffer != null && info.size > 0) {
                    buffer.position(info.offset);
                    buffer.limit(info.offset + info.size);
                    ShortBuffer shorts = buffer.order(ByteOrder.nativeOrder()).asShortBuffer();
                    int count = shorts.remaining();
                    if (raw.length < count) {
                        raw = new short[count];
                    }
                    shorts.get(raw, 0, count);
                    int frames = count / outputChannels;
                    if (mono.length < frames) {
                        mono = new short[frames];
                    }
                    if (outputChannels == 1) {
                        System.arraycopy(raw, 0, mono, 0, frames);
                    } else {
                        for (int i = 0; i < frames; i++) {
                            int sum = 0;
                            for (int c = 0; c < outputChannels; c++) {
                                sum += raw[i * outputChannels + c];
                            }
                            mono[i] = (short) (sum / outputChannels);
                        }
                    }
                    if (outputRate == AdpcmCodec.SAMPLE_RATE) {
                        sink.onPcm(mono, 0, frames);
                    } else {
                        if (resampler == null) {
                            resampler = new Resampler(outputRate, AdpcmCodec.SAMPLE_RATE);
                        }
                        int needed = resampler.maxOutput(frames);
                        if (resampled.length < needed) {
                            resampled = new short[needed];
                        }
                        int written = resampler.process(mono, 0, frames, resampled, 0);
                        if (written > 0) {
                            sink.onPcm(resampled, 0, written);
                        }
                    }
                }
                codec.releaseOutputBuffer(out, false);
            }
        }

        @Override
        public void release() {
            releaseQuietly(codec);
        }

        /** OpusHead（RFC 7845 §5.1）：单声道、48 kHz 下 312 个采样的预跳过、输入采样率 16 kHz、映射族 0。 */
        private static ByteBuffer opusHead() {
            ByteBuffer head = ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN);
            head.put(new byte[] {0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64}); // "OpusHead"
            head.put((byte) 1);
            head.put((byte) 1);
            head.putShort((short) PRE_SKIP_48K);
            head.putInt(AdpcmCodec.SAMPLE_RATE);
            head.putShort((short) 0);
            head.put((byte) 0);
            head.flip();
            return head;
        }

        /** csd-1 / csd-2：64 位整数，单位纳秒，本机字节序（MediaCodec 文档的约定）。 */
        private static ByteBuffer nanoseconds(long value) {
            ByteBuffer buffer = ByteBuffer.allocate(8).order(ByteOrder.nativeOrder());
            buffer.putLong(value);
            buffer.flip();
            return buffer;
        }
    }

    /**
     * 开语音时在后台跑一次：编 25 帧 440 Hz 的音、解回来，要有足够多的包和采样、声音不能是静音、
     * 帧长不能超过包格式允许的 255 字节。返回空串 = 可以用 Opus；否则是原因（会显示在状态里）。
     */
    static String selfTest() {
        if (!encoderSupported()) {
            return "android_below_10";
        }
        Encoder encoder = Encoder.create();
        if (encoder == null) {
            return "no_encoder";
        }
        Decoder decoder = Decoder.create();
        if (decoder == null) {
            encoder.release();
            return "no_decoder";
        }
        try {
            final List<byte[]> encoded = new ArrayList<byte[]>();
            FrameCodec.FrameSink frameSink = new FrameCodec.FrameSink() {
                @Override
                public void onFrame(byte[] data) {
                    encoded.add(data);
                }
            };
            short[] pcm = new short[AdpcmCodec.FRAME_SAMPLES];
            int phase = 0;
            for (int frame = 0; frame < 25; frame++) {
                for (int i = 0; i < pcm.length; i++) {
                    pcm[i] = (short) Math.round(8000 * Math.sin(2 * Math.PI * 440 * phase / (double) AdpcmCodec.SAMPLE_RATE));
                    phase++;
                }
                encoder.encode(pcm, frameSink);
            }
            long deadline = SystemClock.elapsedRealtime() + 500;
            while (encoded.size() < 20 && SystemClock.elapsedRealtime() < deadline) {
                encoder.drain(frameSink, 10000);
            }
            if (encoded.size() < 10) {
                return "few_packets_" + encoded.size();
            }
            for (byte[] data : encoded) {
                if (data.length > VoicePacket.MAX_FRAME_BYTES) {
                    return "frame_too_large_" + data.length;
                }
            }
            final long[] energy = {0};
            final int[] samples = {0};
            FrameCodec.PcmSink pcmSink = new FrameCodec.PcmSink() {
                @Override
                public void onPcm(short[] data, int offset, int length) {
                    for (int i = 0; i < length; i++) {
                        energy[0] += (long) data[offset + i] * data[offset + i];
                    }
                    samples[0] += length;
                }
            };
            for (byte[] data : encoded) {
                long frameDeadline = SystemClock.elapsedRealtime() + 100;
                while (!decoder.decode(data, 0, data.length, pcmSink)) {
                    if (SystemClock.elapsedRealtime() > frameDeadline) {
                        return "decoder_stuck";
                    }
                    decoder.drain(pcmSink, 5000);
                }
            }
            deadline = SystemClock.elapsedRealtime() + 500;
            int target = encoded.size() * AdpcmCodec.FRAME_SAMPLES / 2;
            while (samples[0] < target && SystemClock.elapsedRealtime() < deadline) {
                decoder.drain(pcmSink, 10000);
            }
            if (samples[0] < target) {
                return "few_samples_" + samples[0];
            }
            double rms = Math.sqrt(energy[0] / (double) samples[0]);
            if (rms < 1000) {
                return "silent_output";
            }
            return "";
        } catch (Exception e) {
            Log.w(TAG, "opus self-test failed", e);
            return "exception_" + e.getClass().getSimpleName();
        } finally {
            encoder.release();
            decoder.release();
        }
    }

    static void releaseQuietly(MediaCodec codec) {
        if (codec == null) {
            return;
        }
        try {
            codec.stop();
        } catch (Exception ignored) {
        }
        try {
            codec.release();
        } catch (Exception ignored) {
        }
    }
}
