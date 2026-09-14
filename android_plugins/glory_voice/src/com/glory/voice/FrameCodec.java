package com.glory.voice;

/**
 * 编解码器接口与 ADPCM 实现（docs/聊天系统设计.md 第九节）。纯 Java：VoiceSelfTest 在桌面 JVM 上驱动它。
 *
 * Opus 的实现依赖 MediaCodec（安卓 10 起才有编码器），在 OpusCodec.java。
 * 编码协商靠包头里的 codec 字段（VoicePacket）：收的一方按字段挑解码器，
 * 所以同一个队里有人用 Opus、有人用 ADPCM（安卓 9 及以下、或 Opus 自检没过）也能互相听见。
 */
final class FrameCodec {
    static final int ADPCM = 0;
    static final int OPUS = 1;

    private FrameCodec() {
    }

    interface FrameSink {
        void onFrame(byte[] data);
    }

    interface PcmSink {
        /** 16 kHz 单声道采样。**不许留 pcm 的引用**：调用方会复用这个数组。 */
        void onPcm(short[] pcm, int offset, int length);
    }

    interface Encoder {
        int codecId();

        /**
         * 喂一帧 320 个采样（16 kHz、20 毫秒）。编好的帧交给 sink —— 可能 0 个（编码器有延迟、晚一拍才出），
         * 也可能一次出好几个。不留 pcm 的引用。不许阻塞超过几毫秒（在采集线程里跑）。
         */
        void encode(short[] pcm, FrameSink sink);

        /** 一段话开始时调。ADPCM 从干净状态起步；Opus 什么都不用做（它自己处理得了中间的空白）。 */
        void reset();

        void release();
    }

    interface Decoder {
        /** 把一帧交给解码器；解出来的采样交给 sink（可能晚到）。这一帧不合法返回 false。**不许阻塞**。 */
        boolean decode(byte[] data, int offset, int length, PcmSink sink);

        /** 交出解码器里已经解好、还没交出来的采样（Opus 的输出可能晚一拍）。不许阻塞。 */
        void drain(PcmSink sink);

        void release();
    }

    interface DecoderFactory {
        /** 不支持这种编码、或者解码器建不起来，返回 null。 */
        Decoder create(int codecId);
    }

    static final class AdpcmEncoder implements Encoder {
        private final AdpcmCodec.EncoderState state = new AdpcmCodec.EncoderState();

        @Override
        public int codecId() {
            return ADPCM;
        }

        @Override
        public void encode(short[] pcm, FrameSink sink) {
            byte[] block = new byte[AdpcmCodec.BLOCK_BYTES];
            AdpcmCodec.encodeBlock(pcm, 0, state, block, 0);
            sink.onFrame(block);
        }

        @Override
        public void reset() {
            state.reset();
        }

        @Override
        public void release() {
        }
    }

    static final class AdpcmDecoder implements Decoder {
        private final short[] pcm = new short[AdpcmCodec.FRAME_SAMPLES];

        @Override
        public boolean decode(byte[] data, int offset, int length, PcmSink sink) {
            if (length != AdpcmCodec.BLOCK_BYTES) {
                return false;
            }
            AdpcmCodec.decodeBlock(data, offset, pcm, 0);
            sink.onPcm(pcm, 0, pcm.length);
            return true;
        }

        @Override
        public void drain(PcmSink sink) {
        }

        @Override
        public void release() {
        }
    }

    /** 只认 ADPCM 的解码器工厂：桌面自测用，也是 Opus 解码器建不起来时的退路。 */
    static final DecoderFactory ADPCM_ONLY = new DecoderFactory() {
        @Override
        public Decoder create(int codecId) {
            return codecId == ADPCM ? new AdpcmDecoder() : null;
        }
    };
}
