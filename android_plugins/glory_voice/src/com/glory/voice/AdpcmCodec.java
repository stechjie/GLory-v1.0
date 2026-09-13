package com.glory.voice;

/**
 * 语音编解码：IMA ADPCM，每 20 毫秒一块（docs/聊天系统设计.md 第九节）。
 *
 * 为什么不是 Opus：安卓上的 Opus 要么走 MediaCodec（安卓 10 起才有编码器），要么打原生库
 * （要 NDK，这台机器没有）。ADPCM 每个采样 4 比特（16 kHz 下约 64 kbps）、几十行、
 * 不挑安卓版本、结果确定，足够把「游戏里开麦」验出来。回声消除验过之后再换 Opus
 * （带宽能降到三分之一左右）。
 *
 * 一块（320 个采样 → 163 字节）：[s16 起始预测值 LE][u8 步长序号][160 字节，每字节两个 4 比特，低位在前]。
 * **每块自带解码起点**，任何一块都能单独解：丢一个包只丢那一个包，不会连累后面的。
 *
 * 一个网络包：[u8 版本][u8 标志][u16 首帧序号 LE][u8 帧数][帧数 × 163 字节]。
 *
 * 刻意写成纯 Java（不 import android.*）：VoiceSelfTest 在打包之前用桌面 JVM 跑它。
 */
public final class AdpcmCodec {
    public static final int SAMPLE_RATE = 16000;
    public static final int FRAME_SAMPLES = 320;
    public static final int BLOCK_BYTES = 3 + FRAME_SAMPLES / 2;

    public static final int PACKET_VERSION = 1;
    public static final int PACKET_HEADER_BYTES = 5;
    /** 一段话的第一个包。收的一方据此重新攒缓冲，而不是把两段话之间的静音当成丢包。 */
    public static final int FLAG_SPURT_START = 1;
    public static final int MAX_FRAMES_PER_PACKET = 3;
    /** 494 字节。NetworkService.VOICE_MAX_PACKET_BYTES 不能小于它（tools/voice_check 对账）。 */
    public static final int MAX_PACKET_BYTES = PACKET_HEADER_BYTES + MAX_FRAMES_PER_PACKET * BLOCK_BYTES;

    static final int[] INDEX_TABLE = {-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8};

    static final int[] STEP_TABLE = {
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
        724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
        3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    };

    /** 编码器跨块延续的状态：块与块之间连续，音质才不会每 20 毫秒跳一下。 */
    public static final class EncoderState {
        int predictor;
        int index;

        public void reset() {
            predictor = 0;
            index = 0;
        }
    }

    private AdpcmCodec() {
    }

    /** 把 pcm[offset..offset+320) 编成一块，写到 out[outOffset..outOffset+163)。 */
    public static void encodeBlock(short[] pcm, int offset, EncoderState state, byte[] out, int outOffset) {
        int predictor = state.predictor;
        int index = state.index;
        // 块头写的是**编这一块之前**的状态 —— 解码端从这里起步，才和编码端一致。
        out[outOffset] = (byte) (predictor & 0xff);
        out[outOffset + 1] = (byte) ((predictor >> 8) & 0xff);
        out[outOffset + 2] = (byte) index;
        int nibbleByte = outOffset + 3;
        for (int i = 0; i < FRAME_SAMPLES; i++) {
            int diff = pcm[offset + i] - predictor;
            int nibble = 0;
            if (diff < 0) {
                nibble = 8;
                diff = -diff;
            }
            int step = STEP_TABLE[index];
            int delta = step >> 3;
            if (diff >= step) {
                nibble |= 4;
                diff -= step;
                delta += step;
            }
            step >>= 1;
            if (diff >= step) {
                nibble |= 2;
                diff -= step;
                delta += step;
            }
            step >>= 1;
            if (diff >= step) {
                nibble |= 1;
                delta += step;
            }
            predictor += (nibble & 8) != 0 ? -delta : delta;
            if (predictor > 32767) {
                predictor = 32767;
            } else if (predictor < -32768) {
                predictor = -32768;
            }
            index += INDEX_TABLE[nibble];
            if (index < 0) {
                index = 0;
            } else if (index > 88) {
                index = 88;
            }
            if ((i & 1) == 0) {
                out[nibbleByte] = (byte) nibble;
            } else {
                out[nibbleByte] = (byte) (out[nibbleByte] | (nibble << 4));
                nibbleByte++;
            }
        }
        state.predictor = predictor;
        state.index = index;
    }

    /** 解 in[offset..offset+163) 这一块，写 320 个采样到 out[outOffset..)。不依赖任何前一块。 */
    public static void decodeBlock(byte[] in, int offset, short[] out, int outOffset) {
        int predictor = (short) ((in[offset] & 0xff) | ((in[offset + 1] & 0xff) << 8));
        int index = in[offset + 2] & 0xff;
        if (index > 88) {
            index = 88;
        }
        int nibbleByte = offset + 3;
        for (int i = 0; i < FRAME_SAMPLES; i++) {
            int nibble;
            if ((i & 1) == 0) {
                nibble = in[nibbleByte] & 0x0f;
            } else {
                nibble = (in[nibbleByte] >> 4) & 0x0f;
                nibbleByte++;
            }
            int step = STEP_TABLE[index];
            int delta = step >> 3;
            if ((nibble & 4) != 0) {
                delta += step;
            }
            if ((nibble & 2) != 0) {
                delta += step >> 1;
            }
            if ((nibble & 1) != 0) {
                delta += step >> 2;
            }
            predictor += (nibble & 8) != 0 ? -delta : delta;
            if (predictor > 32767) {
                predictor = 32767;
            } else if (predictor < -32768) {
                predictor = -32768;
            }
            index += INDEX_TABLE[nibble];
            if (index < 0) {
                index = 0;
            } else if (index > 88) {
                index = 88;
            }
            out[outOffset + i] = (short) predictor;
        }
    }

    public static byte[] buildPacket(int seq, boolean spurtStart, byte[][] blocks, int count) {
        byte[] packet = new byte[PACKET_HEADER_BYTES + count * BLOCK_BYTES];
        packet[0] = (byte) PACKET_VERSION;
        packet[1] = (byte) (spurtStart ? FLAG_SPURT_START : 0);
        packet[2] = (byte) (seq & 0xff);
        packet[3] = (byte) ((seq >> 8) & 0xff);
        packet[4] = (byte) count;
        for (int i = 0; i < count; i++) {
            System.arraycopy(blocks[i], 0, packet, PACKET_HEADER_BYTES + i * BLOCK_BYTES, BLOCK_BYTES);
        }
        return packet;
    }

    /**
     * 合法包的帧数；不合法返回 -1。长度必须**正好**等于声明的帧数 ——
     * 只看声明不看实际字节，一个改过的包就能让解码读越界。
     */
    public static int packetFrameCount(byte[] packet) {
        if (packet == null || packet.length < PACKET_HEADER_BYTES + BLOCK_BYTES) {
            return -1;
        }
        if ((packet[0] & 0xff) != PACKET_VERSION) {
            return -1;
        }
        int count = packet[4] & 0xff;
        if (count < 1 || count > MAX_FRAMES_PER_PACKET) {
            return -1;
        }
        if (packet.length != PACKET_HEADER_BYTES + count * BLOCK_BYTES) {
            return -1;
        }
        return count;
    }

    public static int packetSeq(byte[] packet) {
        return (packet[2] & 0xff) | ((packet[3] & 0xff) << 8);
    }

    public static boolean packetSpurtStart(byte[] packet) {
        return (packet[1] & FLAG_SPURT_START) != 0;
    }
}
