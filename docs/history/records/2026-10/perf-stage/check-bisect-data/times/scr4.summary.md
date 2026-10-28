
ts-pattern
| variant | rounds | wall ms | total cycles G | user instructions G | vs main: faster (IQR) / fewer total cycles / fewer user cycles / fewer instructions |
|---|---:|---:|---:|---:|---|
| li | 10 | 845.5 | 3.993 | 8.837 | 3.21% (2.45 to 5.06) / 3.47% / 3.53% / 4.62% |
| li-checker | 10 | 861.9 | 4.060 | 8.974 | 1.75% (1.10 to 2.23) / 1.84% / 1.90% / 3.14% |
| li-ast | 10 | 861.7 | 4.054 | 9.162 | 1.27% (0.85 to 3.05) / 1.27% / 1.53% / 1.11% |
| li-other | 10 | 875.8 | 4.134 | 9.226 | 0.56% (-0.44 to 1.32) / 0.87% / 0.95% / 0.42% |
| null1 | 10 | 871.3 | 4.109 | 9.265 | 0.43% (-0.40 to 2.04) / 0.23% / 0.60% / -0.00% |
| main | 10 | 886.4 | 4.184 | 9.265 |  |

zod3
| variant | rounds | wall ms | total cycles G | user instructions G | vs main: faster (IQR) / fewer total cycles / fewer user cycles / fewer instructions |
|---|---:|---:|---:|---:|---|
| li-checker | 10 | 182.8 | 0.859 | 1.623 | 1.19% (0.26 to 4.43) / 1.86% / 2.29% / 3.35% |
| li-ast | 10 | 182.9 | 0.861 | 1.640 | 1.03% (-0.79 to 2.97) / 0.96% / 1.00% / 2.35% |
| li-other | 10 | 185.3 | 0.871 | 1.673 | 0.44% (-0.21 to 1.70) / 0.28% / 0.36% / 0.41% |
| null1 | 10 | 183.7 | 0.865 | 1.679 | 1.13% (0.16 to 2.61) / 0.56% / 0.60% / 0.01% |
| main | 10 | 186.1 | 0.874 | 1.680 |  |
| li | 10 | 178.6 | 0.841 | 1.575 | 3.78% (2.80 to 5.70) / 3.39% / 3.70% / 6.26% |
