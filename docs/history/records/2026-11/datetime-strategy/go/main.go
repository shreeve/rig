package main
import ("fmt";"time";"math")
func main(){
 for _,s:=range []int64{1700000000, 9223372036, 9223372037, 253402207200, math.MaxInt64, math.MinInt64}{
  t:=time.Unix(s,0); fmt.Println(s, t.UTC(), t.Unix())
 }
 t:=time.Unix(math.MaxInt64,0); fmt.Println(t.Year(), t.Unix())
 t=time.UnixMilli(math.MaxInt64); fmt.Println(t.UTC(), t.UnixMilli())
 t=time.Unix(1,math.MaxInt64); fmt.Println(t.UTC())
 t=time.Unix(0,0).Add(time.Duration(math.MaxInt64)).Add(time.Duration(math.MaxInt64)); fmt.Println(t.UTC())
 big:=1e19; nan:=math.NaN(); one:=time.Duration(math.MaxInt64); one++; fmt.Println(one, time.Duration(big), time.Duration(nan))
 u:=time.Unix(1<<62,0); fmt.Println(u.UTC().Year(), u.Unix())
 y:=time.Date(2262,time.December,1,0,0,0,0,time.UTC); fmt.Println(y.UnixNano(), time.Date(2300,1,1,0,0,0,0,time.UTC).UnixNano())
}
