package com.glory.voice;

/**
 * 把采到的 20 毫秒帧交给编码器，编好的帧凑满 N 帧（或者再加一帧就超长）打成一个包
 * （docs/聊天系统设计.md 第九节）。
 *
 * 编码器可换（ADPCM / Opus），包头带着编码字段，收的一方按字段挑解码器。
 * 只在采集线程里用，不需要同步。纯 Java：VoiceSelfTest 在桌面 JVM 上驱动它。
 */
final class Packetizer {
    interface Sink {
        void onPacket(byte[] packet);
    }

    private final int framesPerPacket;
    private final Sink sink;
    private FrameCodec.Encoder encoder;
    private final byte[][] pending = new byte[VoicePacket.MAX_FRAMES][];
    private int count;
    private int bytes;
    private int pendingCodec = -1;
    private int seq;
    private boolean spurtStart;
    long framesDropped;

    private final FrameCodec.FrameSink frameSink = new FrameCodec.FrameSink() {
        @Override
        public void onFrame(byte[] data) {
            addEncoded(data);
        }
    };

    Packetizer(int framesPerPacket, FrameCodec.Encoder encoder, Sink sink) {
        if (framesPerPacket < 1 || framesPerPacket > VoicePacket.MAX_FRAMES) {
            throw new IllegalArgumentException("framesPerPacket out of range: " + framesPerPacket);
        }
        this.framesPerPacket = framesPerPacket;
        this.encoder = encoder;
        this.sink = sink;
    }

    int codecId() {
        return encoder.codecId();
    }

    /** 换编码器（例如 Opus 自检刚通过）。先把手里凑了一半的包发掉；返回旧编码器，由调用方释放。 */
    FrameCodec.Encoder swapEncoder(FrameCodec.Encoder next) {
        flush();
        FrameCodec.Encoder previous = encoder;
        encoder = next;
        return previous;
    }

    /** 一段话开始：先把上一段没凑满的发掉，编码器回到干净状态，下一个包打上「开头」标志。 */
    void startSpurt() {
        flush();
        encoder.reset();
        spurtStart = true;
    }

    /** 立刻交给编码器，不留 frame 的引用：调用方可以反复复用同一个数组。 */
    void add(short[] frame) {
        encoder.encode(frame, frameSink);
    }

    private void addEncoded(byte[] data) {
        if (data == null || data.length == 0 || data.length > VoicePacket.MAX_FRAME_BYTES) {
            framesDropped++;
            return;
        }
        int codec = encoder.codecId();
        // 同一个包里只能是一种编码；再加这一帧会超长也先发。
        if (count > 0 && (codec != pendingCodec
                || VoicePacket.HEADER_BYTES + bytes + 1 + data.length > VoicePacket.MAX_PACKET_BYTES)) {
            flush();
        }
        pending[count++] = data;
        bytes += 1 + data.length;
        pendingCodec = codec;
        if (count >= framesPerPacket) {
            flush();
        }
    }

    void flush() {
        if (count == 0) {
            return;
        }
        sink.onPacket(VoicePacket.build(seq, spurtStart, pendingCodec, pending, count));
        seq = (seq + count) & 0xffff;
        for (int i = 0; i < count; i++) {
            pending[i] = null;
        }
        count = 0;
        bytes = 0;
        spurtStart = false;
    }

    /** 发掉手里的，释放编码器。采集线程退出前调。 */
    void release() {
        flush();
        if (encoder != null) {
            encoder.release();
        }
    }

    int nextSeq() {
        return seq;
    }
}
