package com.glory.voice;

/**
 * 一个队友传过来的语音：序号校验 + 抖动缓冲 + 解码（docs/聊天系统设计.md 第九节）。
 *
 * push() 在 Godot 的线程里调（JNI），pull() 在混音线程里调。两边都走 synchronized，
 * 临界区只有几次数组读写，不会互相拖住。
 *
 * 纯 Java（不 import android.*）：VoiceSelfTest 在桌面 JVM 上驱动它。
 */
final class RemoteStream {
    /** 攒够这么多帧（60 毫秒）才开始放：吸收网络抖动。 */
    static final int START_FRAMES = 3;
    /** 最多压这么多帧（400 毫秒）。再多就是越积越延迟：宁可丢最老的，也不要一直慢半拍。 */
    static final int MAX_QUEUED_FRAMES = 20;
    /** 这么久没收到包，就当对方说完了；下一个包从头开始（不算丢包、不算迟到）。 */
    static final long IDLE_RESET_MS = 1500;
    /** 攒不够 START_FRAMES、而且这么久没有新包：这段话本来就短，别再等，直接放。 */
    static final long SHORT_SPURT_WAIT_MS = 60;

    private final short[][] ring = new short[MAX_QUEUED_FRAMES][];
    private int head;
    private int size;
    private int expectedSeq = -1;
    private boolean buffering = true;
    /** 播放时放空了。只有同一段话的下一个包真的来了，才算一次欠载（说完话自然放空不算）。 */
    private boolean drained;
    private long lastPushMs = Long.MIN_VALUE / 2;
    private boolean muted;

    long packets;
    long framesLost;
    long packetsLate;
    long packetsBad;
    long underruns;
    long framesDropped;
    volatile float level;

    synchronized void push(byte[] packet, long nowMs) {
        int count = AdpcmCodec.packetFrameCount(packet);
        if (count < 0) {
            packetsBad++;
            return;
        }
        int seq = AdpcmCodec.packetSeq(packet);
        boolean fresh = expectedSeq < 0 || AdpcmCodec.packetSpurtStart(packet)
                || nowMs - lastPushMs > IDLE_RESET_MS;
        if (!fresh) {
            int diff = (seq - expectedSeq) & 0xffff;
            if (diff >= 0x8000) {
                // 比已经收到的还旧：迟到或重复。后面的已经在放了，再放只会是一声杂音。
                packetsLate++;
                return;
            }
            framesLost += diff;
            if (drained) {
                underruns++;
            }
        }
        drained = false;
        lastPushMs = nowMs;
        expectedSeq = (seq + count) & 0xffff;
        packets++;
        if (muted) {
            return;
        }
        for (int i = 0; i < count; i++) {
            short[] frame = new short[AdpcmCodec.FRAME_SAMPLES];
            AdpcmCodec.decodeBlock(packet, AdpcmCodec.PACKET_HEADER_BYTES + i * AdpcmCodec.BLOCK_BYTES, frame, 0);
            if (size == MAX_QUEUED_FRAMES) {
                ring[head] = null;
                head = (head + 1) % MAX_QUEUED_FRAMES;
                size--;
                framesDropped++;
            }
            ring[(head + size) % MAX_QUEUED_FRAMES] = frame;
            size++;
        }
        if (buffering && size >= START_FRAMES) {
            buffering = false;
        }
    }

    /** 下一帧要放的声音；还在攒缓冲或者放空了就是 null。 */
    synchronized short[] pull(long nowMs) {
        if (buffering) {
            if (size > 0 && nowMs - lastPushMs >= SHORT_SPURT_WAIT_MS) {
                buffering = false;
            } else {
                level = 0f;
                return null;
            }
        }
        if (size == 0) {
            buffering = true;
            drained = true;
            level = 0f;
            return null;
        }
        short[] frame = ring[head];
        ring[head] = null;
        head = (head + 1) % MAX_QUEUED_FRAMES;
        size--;
        level = rms(frame);
        return frame;
    }

    synchronized void setMuted(boolean value) {
        muted = value;
        if (value) {
            clearQueue();
        }
    }

    synchronized boolean isMuted() {
        return muted;
    }

    synchronized int queued() {
        return size;
    }

    synchronized boolean isBuffering() {
        return buffering;
    }

    /** 新会话开始时调：清空队列、序号和计数（静音设置保留）。 */
    synchronized void reset() {
        clearQueue();
        expectedSeq = -1;
        lastPushMs = Long.MIN_VALUE / 2;
        packets = 0;
        framesLost = 0;
        packetsLate = 0;
        packetsBad = 0;
        underruns = 0;
        framesDropped = 0;
    }

    private void clearQueue() {
        for (int i = 0; i < MAX_QUEUED_FRAMES; i++) {
            ring[i] = null;
        }
        head = 0;
        size = 0;
        buffering = true;
        drained = false;
        level = 0f;
    }

    static float rms(short[] pcm) {
        if (pcm == null || pcm.length == 0) {
            return 0f;
        }
        long sum = 0;
        for (int i = 0; i < pcm.length; i++) {
            sum += (long) pcm[i] * pcm[i];
        }
        return (float) (Math.sqrt((double) sum / pcm.length) / 32768.0);
    }
}
