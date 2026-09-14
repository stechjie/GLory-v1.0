package com.glory.voice;

/**
 * 一个队友传过来的语音：序号校验 + 解码 + 抖动缓冲（docs/聊天系统设计.md 第九节）。
 *
 * 线程：push() 在 Godot 的线程里调（JNI），**只做校验和入队，不解码**；
 * pull() 在混音线程里调，先把排着的包解掉，再交出一帧。
 * 解码挪到混音线程是被 Opus 逼的：MediaCodec 的输出要等，放在 Godot 线程里每个包都可能卡几毫秒，
 * 两个队友同时说话就是每秒上百次主线程卡顿。两边都走 synchronized，临界区很短（Opus 解码不阻塞）。
 *
 * 纯 Java（不 import android.*）：VoiceSelfTest 用 ADPCM 和假解码器驱动它。
 */
final class RemoteStream {
    /** 攒够这么多帧（60 毫秒）才开始放：吸收网络抖动。 */
    static final int START_FRAMES = 3;
    /** 最多压这么多帧（400 毫秒）。再多就是越积越延迟：宁可丢最老的，也不要一直慢半拍。 */
    static final int MAX_QUEUED_FRAMES = 20;
    /** 还没解的包最多压这么多。正常每 20 毫秒被取走一次，压满说明混音线程停了，丢最老的。 */
    static final int MAX_PENDING_PACKETS = 10;
    /** 这么久没收到包，就当对方说完了；下一个包从头开始（不算丢包、不算迟到）。 */
    static final long IDLE_RESET_MS = 1500;
    /** 攒不够 START_FRAMES、而且这么久没有新包：这段话本来就短，别再等，直接放。 */
    static final long SHORT_SPURT_WAIT_MS = 60;

    private final FrameCodec.DecoderFactory factory;
    private final FrameCodec.Decoder[] decoders = new FrameCodec.Decoder[2];
    private final boolean[] decoderUnavailable = new boolean[2];
    private final VoicePacket.Parsed parsed = new VoicePacket.Parsed();

    private final byte[][] pendingPackets = new byte[MAX_PENDING_PACKETS][];
    private final boolean[] pendingFresh = new boolean[MAX_PENDING_PACKETS];
    private int pendingHead;
    private int pendingSize;

    private final short[][] ring = new short[MAX_QUEUED_FRAMES][];
    private int head;
    private int size;
    private final short[] accum = new short[AdpcmCodec.FRAME_SAMPLES];
    private int accumLength;

    private int expectedSeq = -1;
    private boolean buffering = true;
    /** 播放时放空了。只有同一段话的下一个包真的来了，才算一次欠载（说完话自然放空不算）。 */
    private boolean drained;
    private long lastPushMs = Long.MIN_VALUE / 2;
    private boolean muted;
    private volatile int lastCodec = -1;

    long packets;
    long framesLost;
    long packetsLate;
    long packetsBad;
    long packetsDropped;
    long framesBad;
    long underruns;
    long framesDropped;
    volatile float level;

    private final FrameCodec.PcmSink pcmSink = new FrameCodec.PcmSink() {
        @Override
        public void onPcm(short[] pcm, int offset, int length) {
            appendPcm(pcm, offset, length);
        }
    };

    RemoteStream(FrameCodec.DecoderFactory factory) {
        this.factory = factory;
    }

    /** Godot 线程：只校验、记账、入队。 */
    synchronized void push(byte[] packet, long nowMs) {
        if (!VoicePacket.parse(packet, parsed)) {
            packetsBad++;
            return;
        }
        int seq = parsed.seq;
        boolean fresh = expectedSeq < 0 || parsed.spurtStart || nowMs - lastPushMs > IDLE_RESET_MS;
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
        expectedSeq = (seq + parsed.count) & 0xffff;
        packets++;
        if (muted) {
            return;
        }
        if (pendingSize == MAX_PENDING_PACKETS) {
            pendingPackets[pendingHead] = null;
            pendingHead = (pendingHead + 1) % MAX_PENDING_PACKETS;
            pendingSize--;
            packetsDropped++;
        }
        int slot = (pendingHead + pendingSize) % MAX_PENDING_PACKETS;
        pendingPackets[slot] = packet.clone();
        pendingFresh[slot] = fresh;
        pendingSize++;
    }

    /** 混音线程：解掉排着的包，交出下一帧要放的声音；还在攒缓冲或者放空了就是 null。 */
    synchronized short[] pull(long nowMs) {
        decodePending();
        if (buffering) {
            if (size >= START_FRAMES || (size > 0 && nowMs - lastPushMs >= SHORT_SPURT_WAIT_MS)) {
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

    private void decodePending() {
        while (pendingSize > 0) {
            byte[] packet = pendingPackets[pendingHead];
            boolean fresh = pendingFresh[pendingHead];
            pendingPackets[pendingHead] = null;
            pendingHead = (pendingHead + 1) % MAX_PENDING_PACKETS;
            pendingSize--;
            if (!VoicePacket.parse(packet, parsed)) {
                packetsBad++;
                continue;
            }
            FrameCodec.Decoder decoder = decoderFor(parsed.codec);
            if (decoder == null) {
                // 这台手机解不了这种编码（理论上不会：安卓 5 起都有 Opus 解码器）。记成坏包，不崩。
                packetsBad++;
                continue;
            }
            if (fresh) {
                // 新的一段话：上一段剩下不满一帧的尾巴不要了，否则会拼进这段话的开头。
                accumLength = 0;
            }
            for (int i = 0; i < parsed.count; i++) {
                if (!decoder.decode(packet, parsed.offsets[i], parsed.lengths[i], pcmSink)) {
                    framesBad++;
                }
            }
        }
        for (FrameCodec.Decoder decoder : decoders) {
            if (decoder != null) {
                decoder.drain(pcmSink);
            }
        }
    }

    private FrameCodec.Decoder decoderFor(int codec) {
        if (codec < 0 || codec >= decoders.length) {
            return null;
        }
        if (decoders[codec] == null && !decoderUnavailable[codec]) {
            decoders[codec] = factory.create(codec);
            if (decoders[codec] == null) {
                decoderUnavailable[codec] = true;
            }
        }
        lastCodec = codec;
        return decoders[codec];
    }

    private void appendPcm(short[] pcm, int offset, int length) {
        while (length > 0) {
            int take = Math.min(AdpcmCodec.FRAME_SAMPLES - accumLength, length);
            System.arraycopy(pcm, offset, accum, accumLength, take);
            accumLength += take;
            offset += take;
            length -= take;
            if (accumLength == AdpcmCodec.FRAME_SAMPLES) {
                enqueueFrame(accum.clone());
                accumLength = 0;
            }
        }
    }

    private void enqueueFrame(short[] frame) {
        if (size == MAX_QUEUED_FRAMES) {
            ring[head] = null;
            head = (head + 1) % MAX_QUEUED_FRAMES;
            size--;
            framesDropped++;
        }
        ring[(head + size) % MAX_QUEUED_FRAMES] = frame;
        size++;
    }

    synchronized void setMuted(boolean value) {
        muted = value;
        if (value) {
            clearQueues();
        }
    }

    synchronized boolean isMuted() {
        return muted;
    }

    synchronized int queued() {
        return size;
    }

    synchronized int pendingPackets() {
        return pendingSize;
    }

    synchronized boolean isBuffering() {
        return buffering;
    }

    int lastCodec() {
        return lastCodec;
    }

    /** 新会话开始时调：清空队列、序号和计数，释放解码器（静音设置保留）。 */
    synchronized void reset() {
        clearQueues();
        releaseDecoders();
        expectedSeq = -1;
        lastPushMs = Long.MIN_VALUE / 2;
        lastCodec = -1;
        packets = 0;
        framesLost = 0;
        packetsLate = 0;
        packetsBad = 0;
        packetsDropped = 0;
        framesBad = 0;
        underruns = 0;
        framesDropped = 0;
    }

    /** 混音线程退出之后调（解码器只在混音线程里用，不能边解边放）。 */
    synchronized void releaseDecoders() {
        for (int i = 0; i < decoders.length; i++) {
            if (decoders[i] != null) {
                decoders[i].release();
                decoders[i] = null;
            }
            decoderUnavailable[i] = false;
        }
    }

    private void clearQueues() {
        for (int i = 0; i < MAX_QUEUED_FRAMES; i++) {
            ring[i] = null;
        }
        for (int i = 0; i < MAX_PENDING_PACKETS; i++) {
            pendingPackets[i] = null;
        }
        head = 0;
        size = 0;
        pendingHead = 0;
        pendingSize = 0;
        accumLength = 0;
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
