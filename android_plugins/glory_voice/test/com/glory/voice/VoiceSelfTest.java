package com.glory.voice;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * 打插件包之前在桌面 JVM 上跑的自测（android_plugins/glory_voice/build_aar.ps1 调用，不过就不打包）。
 *
 * 为什么值得：编解码、包格式、序号、重新分帧写坏了，到手机上只会表现成「声音怪」「断断续续」
 * 「偶尔咔一声」，而那时候已经分不清是网络、手机还是代码。这些逻辑不碰安卓 API，能在出包前钉住。
 *
 * Opus 本身（MediaCodec）在这里测不了：它的输出长度不定、还会晚一拍，这两点用假解码器模拟；
 * 真机上由 OpusCodec.selfTest() 在开语音时自检，不过就退回 ADPCM。
 */
public final class VoiceSelfTest {
    private static int failures;

    public static void main(String[] args) {
        codecRoundTrip();
        blockDecodesAlone();
        packetFormat();
        packetizer();
        remoteStream();
        variableLengthDecoder();
        resampler();
        if (failures == 0) {
            System.out.println("VOICE_SELFTEST PASS");
            System.exit(0);
        }
        System.out.println("VOICE_SELFTEST FAIL failures=" + failures);
        System.exit(1);
    }

    private static void check(String name, boolean ok) {
        System.out.println((ok ? "  ok   " : "  FAIL ") + name);
        if (!ok) {
            failures++;
        }
    }

    /** 像说话一样有高有低的信号：三个频率 + 每秒起伏三次的包络。 */
    private static short[] speechLike(int frames, int phaseOffset) {
        short[] pcm = new short[frames * AdpcmCodec.FRAME_SAMPLES];
        for (int i = 0; i < pcm.length; i++) {
            double t = (i + phaseOffset) / (double) AdpcmCodec.SAMPLE_RATE;
            double env = 0.55 + 0.45 * Math.sin(2 * Math.PI * 3 * t);
            double v = env * (0.5 * Math.sin(2 * Math.PI * 220 * t)
                    + 0.3 * Math.sin(2 * Math.PI * 1100 * t)
                    + 0.12 * Math.sin(2 * Math.PI * 2900 * t));
            pcm[i] = (short) Math.round(v * 16000);
        }
        return pcm;
    }

    private static double snrDb(short[] reference, short[] decoded, int from, int to) {
        double signal = 0;
        double noise = 0;
        for (int i = from; i < to; i++) {
            double r = reference[i];
            double e = r - decoded[i];
            signal += r * r;
            noise += e * e;
        }
        if (noise == 0) {
            return 99;
        }
        return 10 * Math.log10(signal / noise);
    }

    private static byte[][] adpcmBlocks(int frames, int phase) {
        short[] pcm = speechLike(frames, phase);
        AdpcmCodec.EncoderState state = new AdpcmCodec.EncoderState();
        byte[][] blocks = new byte[frames][];
        for (int i = 0; i < frames; i++) {
            blocks[i] = new byte[AdpcmCodec.BLOCK_BYTES];
            AdpcmCodec.encodeBlock(pcm, i * AdpcmCodec.FRAME_SAMPLES, state, blocks[i], 0);
        }
        return blocks;
    }

    private static byte[] adpcmPacket(int seq, boolean spurtStart, int frames) {
        return VoicePacket.build(seq, spurtStart, FrameCodec.ADPCM, adpcmBlocks(frames, seq * 7), frames);
    }

    private static byte[] opusLikePacket(int seq, boolean spurtStart, int frames, int bytes) {
        byte[][] data = new byte[frames][];
        for (int i = 0; i < frames; i++) {
            data[i] = new byte[bytes];
            data[i][0] = (byte) (i + 1);
        }
        return VoicePacket.build(seq, spurtStart, FrameCodec.OPUS, data, frames);
    }

    // --- ADPCM ----------------------------------------------------------------------

    private static void codecRoundTrip() {
        check("step table has 89 entries", AdpcmCodec.STEP_TABLE.length == 89);
        check("ADPCM block is 163 bytes", AdpcmCodec.BLOCK_BYTES == 163);
        short[] pcm = speechLike(100, 0);
        short[] out = new short[pcm.length];
        AdpcmCodec.EncoderState state = new AdpcmCodec.EncoderState();
        byte[] block = new byte[AdpcmCodec.BLOCK_BYTES];
        for (int off = 0; off < pcm.length; off += AdpcmCodec.FRAME_SAMPLES) {
            AdpcmCodec.encodeBlock(pcm, off, state, block, 0);
            AdpcmCodec.decodeBlock(block, 0, out, off);
        }
        double snr = snrDb(pcm, out, AdpcmCodec.FRAME_SAMPLES, pcm.length);
        check(String.format("ADPCM round-trip SNR %.1f dB >= 20", snr), snr >= 20.0);

        short[] silence = new short[AdpcmCodec.FRAME_SAMPLES];
        short[] decodedSilence = new short[AdpcmCodec.FRAME_SAMPLES];
        AdpcmCodec.encodeBlock(silence, 0, new AdpcmCodec.EncoderState(), block, 0);
        AdpcmCodec.decodeBlock(block, 0, decodedSilence, 0);
        int peak = 0;
        for (short s : decodedSilence) {
            peak = Math.max(peak, Math.abs(s));
        }
        check("silence decodes to near-silence (peak " + peak + " <= 8)", peak <= 8);

        short[] loud = new short[AdpcmCodec.FRAME_SAMPLES];
        for (int i = 0; i < loud.length; i++) {
            loud[i] = (short) ((i % 2 == 0) ? 32767 : -32768);
        }
        AdpcmCodec.EncoderState extreme = new AdpcmCodec.EncoderState();
        AdpcmCodec.encodeBlock(loud, 0, extreme, block, 0);
        check("full-scale input keeps the step index in range", extreme.index >= 0 && extreme.index <= 88);
    }

    private static void blockDecodesAlone() {
        short[] pcm = speechLike(10, 12345);
        AdpcmCodec.EncoderState state = new AdpcmCodec.EncoderState();
        byte[] block = new byte[AdpcmCodec.BLOCK_BYTES];
        byte[] seventh = new byte[AdpcmCodec.BLOCK_BYTES];
        for (int b = 0; b < 10; b++) {
            AdpcmCodec.encodeBlock(pcm, b * AdpcmCodec.FRAME_SAMPLES, state, block, 0);
            if (b == 7) {
                System.arraycopy(block, 0, seventh, 0, block.length);
            }
        }
        short[] alone = new short[pcm.length];
        AdpcmCodec.decodeBlock(seventh, 0, alone, 7 * AdpcmCodec.FRAME_SAMPLES);
        double snr = snrDb(pcm, alone, 7 * AdpcmCodec.FRAME_SAMPLES, 8 * AdpcmCodec.FRAME_SAMPLES);
        check(String.format("an ADPCM block decodes on its own (SNR %.1f dB >= 20)", snr), snr >= 20.0);
    }

    // --- 包格式 ------------------------------------------------------------------------

    private static void packetFormat() {
        VoicePacket.Parsed parsed = new VoicePacket.Parsed();
        check("limits: packet 494, frame 255", VoicePacket.MAX_PACKET_BYTES == 494 && VoicePacket.MAX_FRAME_BYTES == 255);

        byte[] p = adpcmPacket(65535, true, 2);
        check("v2 ADPCM packet length 6 + 2 x 164", p.length == 334);
        check("v2 ADPCM parses", VoicePacket.parse(p, parsed) && parsed.count == 2
                && parsed.codec == FrameCodec.ADPCM && parsed.seq == 65535 && parsed.spurtStart);
        check("v2 frame offsets", parsed.offsets[0] == 7 && parsed.lengths[0] == 163
                && parsed.offsets[1] == 7 + 163 + 1 && parsed.lengths[1] == 163);

        byte[] o = VoicePacket.build(7, false, FrameCodec.OPUS, new byte[][] {new byte[60], new byte[80]}, 2);
        check("variable-length frames", o.length == 6 + 61 + 81 && VoicePacket.parse(o, parsed)
                && parsed.codec == FrameCodec.OPUS && !parsed.spurtStart
                && parsed.offsets[1] == 6 + 61 + 1 && parsed.lengths[1] == 80);

        byte[] v1 = VoicePacket.buildV1(5, true, adpcmBlocks(2, 0), 2);
        check("legacy v1 packet still parses", v1.length == 331 && VoicePacket.parse(v1, parsed)
                && parsed.codec == FrameCodec.ADPCM && parsed.count == 2 && parsed.offsets[1] == 5 + 163);

        check("truncated packet rejected", !VoicePacket.parse(Arrays.copyOf(p, p.length - 1), parsed));
        check("trailing byte rejected", !VoicePacket.parse(Arrays.copyOf(p, p.length + 1), parsed));
        byte[] unknownCodec = o.clone();
        unknownCodec[5] = 7;
        check("unknown codec rejected", !VoicePacket.parse(unknownCodec, parsed));
        byte[] countTooBig = o.clone();
        countTooBig[4] = 3;
        check("declared count larger than the frames present rejected", !VoicePacket.parse(countTooBig, parsed));
        byte[] countZero = o.clone();
        countZero[4] = 0;
        check("zero frames rejected", !VoicePacket.parse(countZero, parsed));
        byte[] zeroLength = VoicePacket.build(1, false, FrameCodec.OPUS, new byte[][] {new byte[1]}, 1);
        zeroLength[6] = 0;
        check("zero-length frame rejected", !VoicePacket.parse(zeroLength, parsed));
        byte[] shortAdpcm = VoicePacket.build(1, false, FrameCodec.ADPCM, new byte[][] {new byte[100]}, 1);
        check("ADPCM frame must be 163 bytes", !VoicePacket.parse(shortAdpcm, parsed));
        byte[] badVersion = o.clone();
        badVersion[0] = 9;
        check("unknown version rejected", !VoicePacket.parse(badVersion, parsed));
        check("null rejected", !VoicePacket.parse(null, parsed));
    }

    // --- 打包 ------------------------------------------------------------------------

    private static final class FakeEncoder implements FrameCodec.Encoder {
        private final int codec;
        private final int bytes;
        private int delay;

        FakeEncoder(int codec, int bytes, int delay) {
            this.codec = codec;
            this.bytes = bytes;
            this.delay = delay;
        }

        @Override
        public int codecId() {
            return codec;
        }

        @Override
        public void encode(short[] pcm, FrameCodec.FrameSink sink) {
            if (delay > 0) {
                delay--;
                return;
            }
            byte[] data = new byte[bytes];
            data[0] = 1;
            sink.onFrame(data);
        }

        @Override
        public void reset() {
        }

        @Override
        public void release() {
        }
    }

    private static VoicePacket.Parsed parse(byte[] packet) {
        VoicePacket.Parsed parsed = new VoicePacket.Parsed();
        return VoicePacket.parse(packet, parsed) ? parsed : null;
    }

    private static void packetizer() {
        final List<byte[]> sent = new ArrayList<byte[]>();
        Packetizer.Sink sink = new Packetizer.Sink() {
            @Override
            public void onPacket(byte[] packet) {
                sent.add(packet);
            }
        };
        short[] frame = speechLike(1, 0);

        Packetizer adpcm = new Packetizer(2, new FrameCodec.AdpcmEncoder(), sink);
        adpcm.startSpurt();
        for (int i = 0; i < 5; i++) {
            adpcm.add(frame);
        }
        check("ADPCM: 2 full packets after 5 frames", sent.size() == 2);
        adpcm.flush();
        VoicePacket.Parsed a = parse(sent.get(0));
        VoicePacket.Parsed b = parse(sent.get(1));
        VoicePacket.Parsed c = parse(sent.get(2));
        check("flush sends the partial packet", sent.size() == 3 && c != null && c.count == 1);
        check("sequence numbers 0, 2, 4", a != null && b != null && c != null && a.seq == 0 && b.seq == 2 && c.seq == 4);
        check("only the first packet of a spurt is flagged", a.spurtStart && !b.spurtStart && !c.spurtStart);
        check("packets carry the ADPCM codec id", a.codec == FrameCodec.ADPCM && c.codec == FrameCodec.ADPCM);

        sent.clear();
        Packetizer big = new Packetizer(3, new FakeEncoder(FrameCodec.OPUS, 200, 0), sink);
        for (int i = 0; i < 3; i++) {
            big.add(frame);
        }
        big.flush();
        VoicePacket.Parsed first = parse(sent.get(0));
        check("a packet never exceeds " + VoicePacket.MAX_PACKET_BYTES + " bytes (flushes at 2 x 200-byte frames)",
                sent.size() == 2 && first != null && first.count == 2 && sent.get(0).length <= VoicePacket.MAX_PACKET_BYTES);

        sent.clear();
        Packetizer delayed = new Packetizer(2, new FakeEncoder(FrameCodec.OPUS, 40, 1), sink);
        for (int i = 0; i < 3; i++) {
            delayed.add(frame);
        }
        delayed.flush();
        int frames = 0;
        for (byte[] packet : sent) {
            VoicePacket.Parsed parsed = parse(packet);
            frames += parsed == null ? 0 : parsed.count;
        }
        check("a delayed encoder (no output on the first frame) is fine", frames == 2);

        sent.clear();
        Packetizer swap = new Packetizer(2, new FrameCodec.AdpcmEncoder(), sink);
        swap.add(frame);
        swap.swapEncoder(new FakeEncoder(FrameCodec.OPUS, 50, 0)).release();
        swap.add(frame);
        swap.add(frame);
        VoicePacket.Parsed before = sent.size() > 0 ? parse(sent.get(0)) : null;
        VoicePacket.Parsed after = sent.size() > 1 ? parse(sent.get(1)) : null;
        check("swapping encoders flushes first and switches the codec id", sent.size() == 2
                && before != null && before.codec == FrameCodec.ADPCM && before.count == 1
                && after != null && after.codec == FrameCodec.OPUS && after.count == 2 && after.seq == 1);

        sent.clear();
        Packetizer huge = new Packetizer(2, new FakeEncoder(FrameCodec.OPUS, 300, 0), sink);
        huge.add(frame);
        huge.flush();
        check("a frame over 255 bytes is dropped, not sent", sent.isEmpty() && huge.framesDropped == 1);
    }

    // --- 接收 ------------------------------------------------------------------------

    private static void remoteStream() {
        long now = 10000;
        RemoteStream rs = new RemoteStream(FrameCodec.ADPCM_ONLY);
        rs.push(adpcmPacket(65534, true, 1), now);
        check("buffers until 3 frames", rs.pull(now) == null && rs.queued() == 1);
        rs.push(adpcmPacket(65535, false, 2), now + 20);
        check("starts playing at 3 frames", rs.pull(now + 20) != null && rs.queued() == 2);
        rs.push(adpcmPacket(1, false, 2), now + 60);
        check("sequence wraparound is not loss", rs.framesLost == 0 && rs.packetsLate == 0);
        rs.push(adpcmPacket(0, false, 1), now + 70);
        check("late packet dropped", rs.packetsLate == 1);
        rs.push(adpcmPacket(5, false, 1), now + 100);
        check("gap counted as 2 lost frames", rs.framesLost == 2);
        rs.push(new byte[7], now + 110);
        check("malformed packet rejected", rs.packetsBad == 1);

        RemoteStream capped = new RemoteStream(FrameCodec.ADPCM_ONLY);
        int seq = 0;
        for (int i = 0; i < RemoteStream.MAX_PENDING_PACKETS; i++) {
            capped.push(adpcmPacket(seq, i == 0, 3), now + i);
            seq += 3;
        }
        check("pending packets fill up without dropping", capped.pendingPackets() == RemoteStream.MAX_PENDING_PACKETS
                && capped.packetsDropped == 0);
        capped.push(adpcmPacket(seq, false, 3), now + 20);
        check("one more pending packet drops the oldest", capped.packetsDropped == 1);
        capped.pull(now + 21);
        check("decoded frames capped at " + RemoteStream.MAX_QUEUED_FRAMES + " (30 decoded, 10 dropped, 1 played)",
                capped.framesDropped == 10 && capped.queued() == RemoteStream.MAX_QUEUED_FRAMES - 1);

        RemoteStream brief = new RemoteStream(FrameCodec.ADPCM_ONLY);
        brief.push(adpcmPacket(0, true, 2), now);
        check("short spurt waits briefly", brief.pull(now + 10) == null);
        check("short spurt plays once nothing else comes", brief.pull(now + 80) != null);

        RemoteStream under = new RemoteStream(FrameCodec.ADPCM_ONLY);
        under.push(adpcmPacket(0, true, 3), now);
        for (int i = 0; i < 4; i++) {
            under.pull(now + 20 * i);
        }
        check("end of speech is not an underrun", under.underruns == 0);
        under.push(adpcmPacket(3, false, 2), now + 100);
        check("a gap inside the same spurt is an underrun", under.underruns == 1);

        RemoteStream quiet = new RemoteStream(FrameCodec.ADPCM_ONLY);
        quiet.setMuted(true);
        quiet.push(adpcmPacket(0, true, 3), now);
        quiet.pull(now + 100);
        check("muted slot decodes nothing but still counts", quiet.queued() == 0 && quiet.packets == 1);

        RemoteStream idle = new RemoteStream(FrameCodec.ADPCM_ONLY);
        idle.push(adpcmPacket(100, true, 1), now);
        idle.push(adpcmPacket(40, false, 1), now + RemoteStream.IDLE_RESET_MS + 1);
        check("after a long pause an older sequence starts fresh", idle.packetsLate == 0 && idle.packets == 2);

        RemoteStream legacy = new RemoteStream(FrameCodec.ADPCM_ONLY);
        legacy.push(VoicePacket.buildV1(0, true, adpcmBlocks(3, 0), 3), now);
        check("legacy v1 packets still play", legacy.pull(now) != null && legacy.queued() == 2
                && legacy.lastCodec() == FrameCodec.ADPCM);

        RemoteStream noOpus = new RemoteStream(FrameCodec.ADPCM_ONLY);
        noOpus.push(opusLikePacket(0, true, 1, 50), now);
        noOpus.pull(now);
        check("a codec this phone cannot decode counts as bad, never crashes",
                noOpus.packetsBad == 1 && noOpus.queued() == 0);
    }

    /** Opus 解码器的两个特点：输出长度不定（这里每帧 100 个采样）、而且晚一拍（只在 drain 时交出）。 */
    private static final class LaggyDecoder implements FrameCodec.Decoder {
        private int pendingSamples;
        private final short[] buffer = new short[4096];

        @Override
        public boolean decode(byte[] data, int offset, int length, FrameCodec.PcmSink sink) {
            pendingSamples += 100;
            return true;
        }

        @Override
        public void drain(FrameCodec.PcmSink sink) {
            if (pendingSamples == 0) {
                return;
            }
            for (int i = 0; i < pendingSamples; i++) {
                buffer[i] = (short) (1000 + i);
            }
            sink.onPcm(buffer, 0, pendingSamples);
            pendingSamples = 0;
        }

        @Override
        public void release() {
        }
    }

    private static void variableLengthDecoder() {
        final int[] created = {0};
        FrameCodec.DecoderFactory factory = new FrameCodec.DecoderFactory() {
            @Override
            public FrameCodec.Decoder create(int codecId) {
                if (codecId != FrameCodec.OPUS) {
                    return null;
                }
                created[0]++;
                return new LaggyDecoder();
            }
        };
        long now = 50000;
        RemoteStream stream = new RemoteStream(factory);
        stream.push(opusLikePacket(0, true, 2, 40), now);
        stream.push(opusLikePacket(2, false, 2, 40), now + 40);
        stream.pull(now + 40);
        check("variable-length output is re-framed into 320-sample frames (400 samples -> 1 frame)",
                stream.queued() == 1);
        check("one decoder instance per codec", created[0] == 1);
        stream.push(opusLikePacket(4, false, 3, 40), now + 60);
        stream.pull(now + 60);
        check("the 80-sample tail carries into the next frame (80 + 300 -> 1 more frame)", stream.queued() == 2);
        check("stream reports the Opus codec", stream.lastCodec() == FrameCodec.OPUS);
        stream.releaseDecoders();
        stream.push(opusLikePacket(7, false, 1, 40), now + 80);
        stream.pull(now + 80);
        check("decoders are recreated after release", created[0] == 2);
    }

    // --- 重采样 ------------------------------------------------------------------------

    private static void resampler() {
        short[] in = new short[48000 / 4];
        for (int i = 0; i < in.length; i++) {
            in[i] = (short) Math.round(12000 * Math.sin(2 * Math.PI * 440 * i / 48000.0));
        }
        Resampler whole = new Resampler(48000, 16000);
        short[] outWhole = new short[whole.maxOutput(in.length)];
        int nWhole = whole.process(in, 0, in.length, outWhole, 0);
        boolean exact = nWhole >= in.length / 3 - 1;
        for (int j = 0; j < nWhole && exact; j++) {
            exact = outWhole[j] == in[3 * j];
        }
        check("48 kHz -> 16 kHz takes every third sample (" + nWhole + " samples)", exact);

        Resampler chunked = new Resampler(48000, 16000);
        short[] outChunked = new short[nWhole + 16];
        int nChunked = 0;
        int position = 0;
        int[] sizes = {7, 13, 960, 1, 482, 2};
        int index = 0;
        while (position < in.length) {
            int length = Math.min(sizes[index++ % sizes.length], in.length - position);
            short[] tmp = new short[chunked.maxOutput(length)];
            int n = chunked.process(in, position, length, tmp, 0);
            System.arraycopy(tmp, 0, outChunked, nChunked, n);
            nChunked += n;
            position += length;
        }
        boolean same = nChunked == nWhole;
        for (int j = 0; j < nWhole && same; j++) {
            same = outChunked[j] == outWhole[j];
        }
        check("chunked resampling equals one-shot (no clicks at block edges)", same);

        short[] in441 = new short[44100 / 4];
        for (int i = 0; i < in441.length; i++) {
            in441[i] = (short) Math.round(12000 * Math.sin(2 * Math.PI * 440 * i / 44100.0));
        }
        Resampler odd = new Resampler(44100, 16000);
        short[] out441 = new short[odd.maxOutput(in441.length)];
        int n441 = odd.process(in441, 0, in441.length, out441, 0);
        short[] ideal = new short[n441];
        for (int j = 0; j < n441; j++) {
            ideal[j] = (short) Math.round(12000 * Math.sin(2 * Math.PI * 440 * j / 16000.0));
        }
        double snr = snrDb(ideal, out441, 0, n441);
        check(String.format("44.1 kHz -> 16 kHz keeps a clean tone (SNR %.1f dB >= 30)", snr), snr >= 30.0);
    }
}
