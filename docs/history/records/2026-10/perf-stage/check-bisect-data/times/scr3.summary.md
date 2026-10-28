
ts-pattern
| variant | rounds | wall ms | total cycles G | user instructions G | vs main: faster (IQR) / fewer total cycles / fewer user cycles / fewer instructions |
|---|---:|---:|---:|---:|---|
| li | 10 | 861.7 | 4.079 | 8.837 | 2.85% (1.99 to 3.88) / 2.64% / 3.68% / 4.62% |
| li-checker | 10 | 863.4 | 4.076 | 8.974 | 1.53% (1.00 to 1.92) / 1.08% / 1.44% / 3.14% |
| li-store | 10 | 875.3 | 4.129 | 9.265 | -0.58% (-1.42 to 0.23) / -0.74% / -0.52% / -0.00% |
| li-members | 10 | 865.5 | 4.084 | 9.212 | 0.45% (0.26 to 0.82) / 0.19% / 0.29% / 0.57% |
| main | 10 | 881.5 | 4.167 | 9.265 |  |

zod3
| variant | rounds | wall ms | total cycles G | user instructions G | vs main: faster (IQR) / fewer total cycles / fewer user cycles / fewer instructions |
|---|---:|---:|---:|---:|---|
| li | 10 | 166.1 | 0.782 | 1.575 | 3.99% (3.35 to 5.70) / 3.55% / 4.11% / 6.26% |
| li-checker | 10 | 169.5 | 0.795 | 1.623 | 2.22% (1.64 to 2.81) / 2.53% / 2.87% / 3.36% |
| li-store | 10 | 171.3 | 0.798 | 1.679 | 1.40% (0.48 to 2.25) / 1.28% / 1.49% / 0.00% |
| li-members | 10 | 171.7 | 0.806 | 1.676 | 0.58% (-0.90 to 1.90) / 0.95% / 0.59% / 0.24% |
| main | 10 | 173.5 | 0.809 | 1.680 |  |
