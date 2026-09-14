package com.glory.voice;

/**
 * 单声道 PCM 线性重采样，跨调用保持位置 —— 分块喂进来和一次喂进来结果一样，块边界不会咔一声。
 * 纯 Java：VoiceSelfTest 在桌面 JVM 上驱动它。
 *
 * 用在 Opus 解码之后：安卓的软件 Opus 解码器**固定输出 48 kHz**（AOSP C2SoftOpusDec 的 kRate），
 * 而混音和播放是 16 kHz。按 16 kHz 编码的 Opus 本身就把频带限在 8 kHz 以内，
 * 所以 48 kHz → 16 kHz 直接抽取不会混叠，线性插值足够。
 */
final class Resampler {
    private final double step;
    /** 下一个输出点的位置，以「当前这一块的第一个采样」为 0；在 [-1, 0) 表示落在上一块最后一个采样与这一块第一个采样之间。 */
    private double position;
    private int previous;

    Resampler(int inRate, int outRate) {
        if (inRate <= 0 || outRate <= 0) {
            throw new IllegalArgumentException("sample rates must be positive");
        }
        this.step = inRate / (double) outRate;
    }

    /** 最多会写出多少个采样（给调用方分配输出数组用）。 */
    int maxOutput(int inputLength) {
        return (int) Math.ceil(inputLength / step) + 2;
    }

    /** 把 in[offset..offset+length) 重采样后写进 out[outOffset..)，返回写出的采样数。 */
    int process(short[] in, int offset, int length, short[] out, int outOffset) {
        if (length <= 0) {
            return 0;
        }
        int written = 0;
        while (true) {
            int k = (int) Math.floor(position);
            if (k + 1 >= length) {
                // 要用到下一块的第一个采样了，留到下一次。
                break;
            }
            double fraction = position - k;
            int a = k < 0 ? previous : in[offset + k];
            int b = in[offset + k + 1];
            out[outOffset + written++] = (short) Math.round(a + (b - a) * fraction);
            position += step;
        }
        previous = in[offset + length - 1];
        position -= length;
        return written;
    }

    void reset() {
        position = 0.0;
        previous = 0;
    }
}
