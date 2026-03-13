# Kiraa standard sales summary transform
filter(status == "active")                    |
filter(revenue > 10000)                       |
groupby(region, quarter)                      |
agg(sum:revenue, mean:margin, count:transactions) |
sort(revenue, desc)                           |
rename(revenue -> total_revenue)              |
rename(margin -> avg_margin)                  |
round(avg_margin, 3)
