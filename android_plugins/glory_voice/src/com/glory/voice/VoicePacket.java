package com.glory.voice;

/**
 * 语音网络包的格式（docs/聊天系统设计.md 第九节）。纯 Java：VoiceSelfTest 在桌面 JVM 上驱动它。
 *
 * v2（现在发的）：[u8 版本=2][u8 标志][u16 首帧序号 LE][u8 帧数][u8 编码] + 帧数 × ([u8 帧长][帧])
 * v1（09-13 第一版，只有 ADPCM）：[u8 版本=1][u8 标志][u16 首帧序号 LE][u8 帧数] + 帧数 × 163 字节
 *
 * 新包仍然认 v1：手里还没换包的同事发过来的声音照样能放。反过来不行 —— 旧包只认 v1，
 * 听不到新包发的声音。所以换包时同一队要一起换。
 *
 * ③ 不解析这个格式，只限总长度（NetworkService.VOICE_MAX_PACKET_BYTES = 512），所以改格式不用顶协议号。
 */
final class VoicePacket {
    static final int VERSION_V1 = 1;
    static final int VERSION = 2;
    static final int V1_HEADER_BYTES = 5;
    static final int HEADER_BYTES = 6;
    /** 一段话的第一个包。收的一方据此重新攒缓冲，而不是把两段话之间的静音当成丢包。 */
    static final int FLAG_SPURT_START = 1;
    static final int MAX_FRAMES = 3;
    static final int MAX_FRAME_BYTES = 255;
    /** 打包时再加一帧就超过这个长度就先发。NetworkService.VOICE_MAX_PACKET_BYTES 不能小于它（tools/voice_check 对账）。 */
    static final int MAX_PACKET_BYTES = 494;

    private VoicePacket() {
    }

    static final class Parsed {
        int seq;
        boolean spurtStart;
        int codec;
        int count;
        final int[] offsets = new int[MAX_FRAMES];
        final int[] lengths = new int[MAX_FRAMES];
    }

    /** 这几帧打成一个 v2 包之后有多长。 */
    static int size(byte[][] frames, int count) {
        int size = HEADER_BYTES;
        for (int i = 0; i < count; i++) {
            size += 1 + frames[i].length;
        }
        return size;
    }

    static byte[] build(int seq, boolean spurtStart, int codec, byte[][] frames, int count) {
        byte[] packet = new byte[size(frames, count)];
        packet[0] = (byte) VERSION;
        packet[1] = (byte) (spurtStart ? FLAG_SPURT_START : 0);
        packet[2] = (byte) (seq & 0xff);
        packet[3] = (byte) ((seq >> 8) & 0xff);
        packet[4] = (byte) count;
        packet[5] = (byte) codec;
        int offset = HEADER_BYTES;
        for (int i = 0; i < count; i++) {
            packet[offset++] = (byte) frames[i].length;
            System.arraycopy(frames[i], 0, packet, offset, frames[i].length);
            offset += frames[i].length;
        }
        return packet;
    }

    /** v1 格式的包。只给自测用：证明新包还能解第一版发出来的声音。 */
    static byte[] buildV1(int seq, boolean spurtStart, byte[][] adpcmBlocks, int count) {
        byte[] packet = new byte[V1_HEADER_BYTES + count * AdpcmCodec.BLOCK_BYTES];
        packet[0] = (byte) VERSION_V1;
        packet[1] = (byte) (spurtStart ? FLAG_SPURT_START : 0);
        packet[2] = (byte) (seq & 0xff);
        packet[3] = (byte) ((seq >> 8) & 0xff);
        packet[4] = (byte) count;
        for (int i = 0; i < count; i++) {
            System.arraycopy(adpcmBlocks[i], 0, packet, V1_HEADER_BYTES + i * AdpcmCodec.BLOCK_BYTES,
                    AdpcmCodec.BLOCK_BYTES);
        }
        return packet;
    }

    /**
     * 合法就填好 out、返回 true。长度必须**正好**对上：多一个字节、少一个字节、帧长为 0、
     * 声明的帧数与实际不符都算坏包 —— 只看声明不看实际字节，一个改过的包就能让解码读越界。
     */
    static boolean parse(byte[] packet, Parsed out) {
        if (packet == null || packet.length < V1_HEADER_BYTES + 1) {
            return false;
        }
        int version = packet[0] & 0xff;
        int count = packet[4] & 0xff;
        if (count < 1 || count > MAX_FRAMES) {
            return false;
        }
        out.seq = (packet[2] & 0xff) | ((packet[3] & 0xff) << 8);
        out.spurtStart = (packet[1] & FLAG_SPURT_START) != 0;
        out.count = count;
        if (version == VERSION_V1) {
            if (packet.length != V1_HEADER_BYTES + count * AdpcmCodec.BLOCK_BYTES) {
                return false;
            }
            out.codec = FrameCodec.ADPCM;
            for (int i = 0; i < count; i++) {
                out.offsets[i] = V1_HEADER_BYTES + i * AdpcmCodec.BLOCK_BYTES;
                out.lengths[i] = AdpcmCodec.BLOCK_BYTES;
            }
            return true;
        }
        if (version != VERSION || packet.length < HEADER_BYTES + 2) {
            return false;
        }
        int codec = packet[5] & 0xff;
        if (codec != FrameCodec.ADPCM && codec != FrameCodec.OPUS) {
            return false;
        }
        int offset = HEADER_BYTES;
        for (int i = 0; i < count; i++) {
            if (offset >= packet.length) {
                return false;
            }
            int length = packet[offset] & 0xff;
            offset++;
            if (length == 0 || offset + length > packet.length) {
                return false;
            }
            if (codec == FrameCodec.ADPCM && length != AdpcmCodec.BLOCK_BYTES) {
                return false;
            }
            out.offsets[i] = offset;
            out.lengths[i] = length;
            offset += length;
        }
        if (offset != packet.length) {
            return false;
        }
        out.codec = codec;
        return true;
    }
}
