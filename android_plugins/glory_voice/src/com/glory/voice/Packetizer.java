package com.glory.voice;

/**
 * 把采到的 20 毫秒帧编码、凑满 N 帧打成一个包（docs/聊天系统设计.md 第九节）。
 *
 * 只在采集线程里用，不需要同步。纯 Java：VoiceSelfTest 在桌面 JVM 上驱动它。
 */
final class Packetizer {
    interface Sink {
        void onPacket(byte[] packet);
    }

    private final int framesPerPacket;
    private final Sink sink;
    private final AdpcmCodec.EncoderState encoder = new AdpcmCodec.EncoderState();
    private final byte[][] pending;
    private int count;
    private int seq;
    private boolean spurtStart;

    Packetizer(int framesPerPacket, Sink sink) {
        if (framesPerPacket < 1 || framesPerPacket > AdpcmCodec.MAX_FRAMES_PER_PACKET) {
            throw new IllegalArgumentException("framesPerPacket out of range: " + framesPerPacket);
        }
        this.framesPerPacket = framesPerPacket;
        this.sink = sink;
        this.pending = new byte[framesPerPacket][];
    }

    /** 一段话开始：先把上一段没凑满的发掉，再从干净的编码状态开始，下一个包打上开头标志。 */
    void startSpurt() {
        flush();
        encoder.reset();
        spurtStart = true;
    }

    /** 立刻编码，不留 frame 的引用：调用方可以反复复用同一个数组。 */
    void add(short[] frame) {
        byte[] block = new byte[AdpcmCodec.BLOCK_BYTES];
        AdpcmCodec.encodeBlock(frame, 0, encoder, block, 0);
        pending[count++] = block;
        if (count == framesPerPacket) {
            flush();
        }
    }

    void flush() {
        if (count == 0) {
            return;
        }
        sink.onPacket(AdpcmCodec.buildPacket(seq, spurtStart, pending, count));
        seq = (seq + count) & 0xffff;
        for (int i = 0; i < count; i++) {
            pending[i] = null;
        }
        count = 0;
        spurtStart = false;
    }

    int nextSeq() {
        return seq;
    }
}
