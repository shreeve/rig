
ts-pattern
| variant | rounds | wall ms | total cycles G | user instructions G | vs pgo-main: faster (IQR) / fewer total cycles / fewer user cycles / fewer instructions |
|---|---:|---:|---:|---:|---|
| pgo-li | 20 | 804.1 | 3.804 | 7.738 | 3.09% (1.49 to 5.01) / 3.18% / 3.28% / 5.09% |
| pgo-ov | 20 | 815.8 | 3.861 | 7.973 | 1.50% (0.17 to 3.85) / 1.69% / 2.10% / 2.21% |
| pgo-accast | 20 | 811.5 | 3.851 | 7.929 | 2.27% (-1.50 to 3.33) / 2.25% / 2.50% / 2.76% |
| pgo-main | 20 | 835.5 | 3.963 | 8.154 |  |

zod3
| variant | rounds | wall ms | total cycles G | user instructions G | vs pgo-main: faster (IQR) / fewer total cycles / fewer user cycles / fewer instructions |
|---|---:|---:|---:|---:|---|
| pgo-accast | 20 | 153.6 | 0.720 | 1.363 | 3.63% (0.82 to 4.99) / 4.21% / 4.62% / 4.65% |
| pgo-main | 20 | 159.0 | 0.748 | 1.430 |  |
| pgo-li | 20 | 153.0 | 0.721 | 1.335 | 3.91% (2.27 to 5.63) / 3.63% / 4.14% / 6.61% |
| pgo-ov | 20 | 157.8 | 0.740 | 1.405 | -0.02% (-1.80 to 2.66) / 0.51% / 1.28% / 1.76% |
