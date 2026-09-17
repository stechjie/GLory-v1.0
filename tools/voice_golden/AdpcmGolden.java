import com.glory.voice.AdpcmCodec;

/**
 * Golden vectors for the desktop voice port (scripts/voice/VoiceAdpcm.gd).
 *
 * The desktop backend must produce and accept byte-for-byte the same IMA ADPCM
 * blocks as the Android plugin, or phone <-> PC voice turns into noise with no
 * error anywhere. This program runs the real Android codec
 * (android_plugins/glory_voice/src/com/glory/voice/AdpcmCodec.java) on a fixed
 * input and prints the result as JSON; tools/voice_check compares the GDScript
 * port against it.
 *
 * The input is integer-only (no Math.sin) so it is identical on every JVM, and it
 * is stored in the fixture anyway. Regenerate with tools/voice_adpcm_golden.ps1.
 */
public final class AdpcmGolden {
    private static final int FRAMES = 4;

    public static void main(String[] args) {
        int n = AdpcmCodec.FRAME_SAMPLES * FRAMES;
        short[] pcm = new short[n];
        long lcg = 12345;
        for (int i = 0; i < n; i++) {
            int frame = i / AdpcmCodec.FRAME_SAMPLES;
            int t = i % AdpcmCodec.FRAME_SAMPLES;
            int v;
            if (frame == 0) {
                // near-silence: exercises the smallest step sizes
                v = (t % 7) * 6 - 18;
            } else if (frame == 1) {
                // triangle wave, period 36 samples, amplitude 12000
                int p = t % 36;
                v = (p < 18 ? p : 36 - p) * 1333 - 12000;
            } else if (frame == 2) {
                // pseudo-random noise in [-20000, 20000]
                lcg = (lcg * 1103515245L + 12345L) & 0x7fffffffL;
                v = (int) (lcg % 40001L) - 20000;
            } else {
                // full-scale square wave: exercises predictor clamping at both ends
                v = ((t / 16) % 2 == 0) ? 32767 : -32768;
            }
            pcm[i] = (short) v;
        }

        AdpcmCodec.EncoderState state = new AdpcmCodec.EncoderState();
        byte[][] blocks = new byte[FRAMES][AdpcmCodec.BLOCK_BYTES];
        short[] decoded = new short[n];
        for (int f = 0; f < FRAMES; f++) {
            AdpcmCodec.encodeBlock(pcm, f * AdpcmCodec.FRAME_SAMPLES, state, blocks[f], 0);
            AdpcmCodec.decodeBlock(blocks[f], 0, decoded, f * AdpcmCodec.FRAME_SAMPLES);
        }

        StringBuilder out = new StringBuilder();
        out.append("{\n");
        out.append("  \"generator\": \"tools/voice_golden/AdpcmGolden.java\",\n");
        out.append("  \"frame_samples\": ").append(AdpcmCodec.FRAME_SAMPLES).append(",\n");
        out.append("  \"block_bytes\": ").append(AdpcmCodec.BLOCK_BYTES).append(",\n");
        out.append("  \"pcm_le_hex\": \"").append(shortsHex(pcm)).append("\",\n");
        out.append("  \"blocks_hex\": [\n");
        for (int f = 0; f < FRAMES; f++) {
            out.append("    \"").append(bytesHex(blocks[f])).append("\"");
            out.append(f + 1 < FRAMES ? ",\n" : "\n");
        }
        out.append("  ],\n");
        out.append("  \"decoded_le_hex\": \"").append(shortsHex(decoded)).append("\"\n");
        out.append("}\n");
        System.out.print(out);
    }

    private static String bytesHex(byte[] data) {
        StringBuilder sb = new StringBuilder(data.length * 2);
        for (byte b : data) {
            sb.append(String.format("%02x", b & 0xff));
        }
        return sb.toString();
    }

    private static String shortsHex(short[] data) {
        StringBuilder sb = new StringBuilder(data.length * 4);
        for (short s : data) {
            sb.append(String.format("%02x%02x", s & 0xff, (s >> 8) & 0xff));
        }
        return sb.toString();
    }
}
