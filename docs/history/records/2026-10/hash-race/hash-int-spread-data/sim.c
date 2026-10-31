// The table of src/unordered.zig, for screening integer-hash multipliers.
// ./sim MUL... : one line of features per multiplier.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
typedef uint64_t u64;
static u64 rotl8(u64 x){return (x<<8)|(x>>56);}
static u64 scat(u64 n){u64 z=(n+1)*0x9e3779b97f4a7c15ULL; z=(z^(z>>30))*0xbf58476d1ce4e5b9ULL; z=(z^(z>>27))*0x94d049bb133111ebULL; return z^(z>>31);}
static int tagof(u64 t){int b=t&0xff; return b<2?b+8:b;}
typedef struct { int W,NL,ln,ld,ming; u64 G; int sh; u64 *h; unsigned char *cnt,*ovf; size_t size,ml; } T;
static long probesteps(T*t);
static double rndfm(u64 mul,int W,size_t s,u64 a,u64 b,double*gvp);
static void tinit(T*t,int W){memset(t,0,sizeof *t);t->W=W;t->NL=W-1;t->ln=W==8?4:7;t->ld=W==8?5:8;t->ming=W==8?4:2;}
static u64 groupsFor(T*t,size_t n){u64 x=n/t->NL+1; if(x<(u64)t->ming)x=t->ming; u64 p=1; while(p<x)p<<=1; return p;}
static int lg(u64 g){int r=0; while((1ULL<<r)<g)r++; return r;}
// rehash K1: placements whose loads meet the group the placement before stored to
static long rh_k1, rh_k2, rh_moves, ins_k1, ins_k2; static int last_st=-1, last_st2=-1; static long ist1=-1, ist2=-1;
static u64 place(T*t,u64 h,int count_rh){
  u64 p=h>>t->sh, st=0; int hit=0, hit2=0;
  if(count_rh && (long)p==last_st) hit=1;
  if(count_rh && (long)p==last_st2) hit2=1;
  while(t->cnt[p]>=t->NL-(p==t->G-1)){ t->ovf[p]|=1<<(h&7); st++; p=(p+st)&(t->G-1); if(count_rh && (long)p==last_st) hit=1; if(count_rh && (long)p==last_st2) hit2=1; }
  t->h[p*t->NL+t->cnt[p]]=h; t->cnt[p]++;
  if(count_rh){ rh_k1+=hit; rh_k2+=(hit||hit2); rh_moves++; last_st2=last_st; last_st=p; }
  return p;
}
static void build(T*t,size_t n){
  u64 G=groupsFor(t,n); u64 *nh=calloc(G*t->NL,8); unsigned char *nc=calloc(G,1),*no=calloc(G,1);
  u64 oG=t->G; u64*oh=t->h; unsigned char*oc=t->cnt;
  t->G=G; t->sh=64-lg(G); t->h=nh; t->cnt=nc; t->ovf=no;
  size_t c=G*t->NL-1; t->ml= c<= (size_t)(2*t->NL-1) ? c : c*t->ln/t->ld;
  last_st=-1; last_st2=-1;
  if(oh){ for(u64 g=0;g<oG;g++) for(int l=0;l<oc[g];l++) place(t,oh[g*t->NL+l],1); free(oh); free(oc);}
}
static void tfree(T*t){free(t->h);free(t->cnt);free(t->ovf);t->h=0;t->cnt=0;t->ovf=0;t->G=0;t->size=0;t->ml=0;}
static void insert(T*t,u64 h){
  if(t->size>=t->ml){ size_t s=t->size; size_t n=((s+s/61+1)*t->ld + t->ln-1)/t->ln; build(t,n); }
  u64 p0=h>>t->sh; long p=place(t,h,0);
  // the insert path: home load against the last two inserts' stores
  if((long)p0==ist1) ins_k1++; else if((long)p0==ist2) ins_k2++;
  ist2=ist1; ist1=p; t->size++;
}
// a miss: groups visited and false tag matches
static void miss(T*t,u64 h,long*gv,long*fm){
  u64 p=h>>t->sh, st=0; int tg=tagof(h);
  for(;;){ (*gv)++; for(int l=0;l<t->cnt[p];l++) if(tagof(t->h[p*t->NL+l])==tg) (*fm)++;
    if(!(t->ovf[p]&(1<<(h&7)))) break; st++; p=(p+st)&(t->G-1); }
}
static void hitfm(T*t,u64 h,long*fm){
  u64 p=h>>t->sh, st=0; int tg=tagof(h);
  for(;;){ for(int l=0;l<t->cnt[p];l++){ u64 x=t->h[p*t->NL+l]; if(x==h) return; if(tagof(x)==tg) (*fm)++; }
    st++; p=(p+st)&(t->G-1); }
}
static double rndhit(u64 mul,int W,size_t s){ T t; tinit(&t,W); for(size_t i=0;i<s;i++) insert(&t,rotl8(scat(i)*mul)); long fm=0; for(size_t i=0;i<s;i++) hitfm(&t,rotl8(scat(i)*mul),&fm); tfree(&t); return (double)fm/s; }
static double rnddisp(u64 mul,int W,size_t s){ T t; tinit(&t,W); for(size_t i=0;i<s;i++) insert(&t,rotl8(scat(i)*mul)); long ps=probesteps(&t); tfree(&t); return (double)ps/s; }
static int rndworse(u64 mul){ /* any random row's groups visited a miss, or displaced keys, over main's */
  static double mg[2][4],md[2][4]; static int init=0; static const size_t rs[]={16,24,1000,1500}; u64 M0=0x4b33a62ed433d4a3ULL;
  if(!init){ for(int w=0;w<2;w++) for(int q=0;q<4;q++){ rndfm(M0,w?8:16,rs[q],0,8000000,&mg[w][q]); md[w][q]=rnddisp(M0,w?8:16,rs[q]); } init=1; }
  for(int w=0;w<2;w++) for(int q=0;q<4;q++){ double g; rndfm(mul,w?8:16,rs[q],0,8000000,&g); if(g>mg[w][q]+1e-9) return 1; if(rnddisp(mul,w?8:16,rs[q])>md[w][q]+1e-9) return 1; }
  return 0; }
static double H5(u64 mul,int W,size_t sz){ T t; tinit(&t,W); for(size_t k=0;k<sz;k++) insert(&t,rotl8(((u64)k)*0x9e3779b97f4a7c15ULL*mul));
  static long ctx[1<<20][16]; static int used[1<<20]; static unsigned keys[1<<20]; int nk=0; u64 Gm=t.G;
  for(u64 g=0;g<Gm;g++){ unsigned key=0; for(int j=1;j<=5;j++) key=key*16+t.cnt[(g+Gm-j)%Gm]; key&=(1<<20)-1; if(!used[key]){used[key]=1; memset(ctx[key],0,sizeof ctx[key]); keys[nk++]=key;} ctx[key][t.cnt[g]]++; }
  double H=0; for(int q=0;q<nk;q++){ long tot=0; for(int o=0;o<16;o++) tot+=ctx[keys[q]][o]; for(int o=0;o<16;o++) if(ctx[keys[q]][o]){ double p=(double)ctx[keys[q]][o]/tot; H-=ctx[keys[q]][o]*__builtin_log2(p);} used[keys[q]]=0; }
  tfree(&t); return H/Gm; }
// golden int rows: map of i*G for i<s; misses s..2s: groups visited + false matches a miss, false matches a hit
static void introw(u64 mul,int W,size_t s,double*gv,double*fm,double*hfm){ T t; tinit(&t,W); for(size_t i=0;i<s;i++) insert(&t,rotl8(((u64)i)*0x9e3779b97f4a7c15ULL*mul)); long g=0,f=0,h=0;
  for(size_t i=s;i<2*s;i++) miss(&t,rotl8(((u64)i)*0x9e3779b97f4a7c15ULL*mul),&g,&f); for(size_t i=0;i<s;i++) hitfm(&t,rotl8(((u64)i)*0x9e3779b97f4a7c15ULL*mul),&h);
  *gv=(double)g/s; *fm=(double)f/s; *hfm=(double)h/s; tfree(&t); }
// walk mispredicts: each group's occupancy predicted as the one that last
// followed the same K occupancies before it, in steady state (second round)
static double walkmp(u64 mul,int W,size_t sz,int K){ T t; tinit(&t,W); for(size_t k=0;k<sz;k++) insert(&t,rotl8(((u64)k)*0x9e3779b97f4a7c15ULL*mul));
  u64 G=t.G; size_t cap=1; while(cap<4*G) cap<<=1; u64*key=malloc(cap*8); unsigned char*val=malloc(cap); unsigned char*use=calloc(cap,1); long miss=0;
  for(int r=0;r<2;r++) for(u64 g=0;g<G;g++){ u64 k=1; for(int j=1;j<=K;j++) k=k*16+t.cnt[(g+G-j)%G]; size_t h=(k*0x9e3779b97f4a7c15ULL)>>(64-__builtin_ctzll(cap)); 
    while(use[h]&&key[h]!=k) h=(h+1)&(cap-1);
    if(r==1){ if(!use[h]||val[h]!=t.cnt[g]) miss++; }
    use[h]=1; key[h]=k; val[h]=t.cnt[g]; }
  free(key);free(val);free(use); tfree(&t); return (double)miss/G; }
static long probesteps(T*t){ long s=0; for(u64 g=0;g<t->G;g++) for(int l=0;l<t->cnt[g];l++){ u64 h=t->h[g*t->NL+l]; u64 p=h>>t->sh,st=0; while(p!=g){st++;p=(p+st)&(t->G-1);} s+=st;} return s; }
static const u64 GOLD=0x9e3779b97f4a7c15ULL;
// rehash K1 per insert for s keys a map, k maps, golden stride, keys (j*s+i)*G
static double rowk2(u64 mul,int W,size_t s,int k);
static double rowk1(u64 mul,int W,size_t s,int k){ rh_k1=0; rh_k2=0; long n=0; for(int j=0;j<k;j++){ T t; tinit(&t,W); for(size_t i=0;i<s;i++){ insert(&t,rotl8(((u64)(j*s+i))*GOLD*mul)); n++; } tfree(&t);} return (double)rh_k1/n; }
static double rowins(u64 mul,int W,size_t s,int k,double*k2){ ins_k1=ins_k2=0; long n=0; for(int j=0;j<k;j++){ T t; tinit(&t,W); ist1=ist2=-1; for(size_t i=0;i<s;i++){ insert(&t,rotl8(((u64)(j*s+i))*GOLD*mul)); n++; } tfree(&t);} *k2=(double)ins_k2/n; return (double)ins_k1/n; }
static double rndfm(u64 mul,int W,size_t s,u64 a,u64 b,double*gvp){ T t; tinit(&t,W); for(size_t i=0;i<s;i++) insert(&t,rotl8(scat(a+i)*mul)); long gv=0,fm=0; for(size_t i=0;i<s;i++) miss(&t,rotl8(scat(b+i)*mul),&gv,&fm); tfree(&t); if(gvp)*gvp=(double)gv/s; return (double)fm/s; }
static int spread(u64 mul,int W,double*worst){
  static const u64 strides[]={1,2,3,5,7,8,16,64,100,1000,1000000,1<<10,1<<20,1ULL<<32,1ULL<<40,(1ULL<<32)+1,0x9e3779b97f4a7c15ULL};
  static const size_t sizes[]={16,100,256,500,1000,2000,3000,4096,5000,8192,10000,16384,20000,50000,100000};
  int bad=0; *worst=0;
  for(int a=0;a<17;a++) for(int b=0;b<15;b++){ T t; tinit(&t,W); size_t n=sizes[b]; for(size_t i=0;i<n;i++) insert(&t,rotl8(i*strides[a]*mul)); long ps=probesteps(&t); double r=(double)ps/n; if(r>*worst)*worst=r; if(ps*4>(long)n) bad++; tfree(&t);} 
  return bad;
}
static u64 rng=0x123456789abcdefULL; static u64 next(){ rng+=0x9e3779b97f4a7c15ULL; u64 z=rng; z=(z^(z>>30))*0xbf58476d1ce4e5b9ULL; z=(z^(z>>27))*0x94d049bb133111ebULL; return z^(z>>31);}
static long stage[32];
static int search(long count,u64 seed){
  rng=seed; long pass=0;
  // main's values: every row's no worse than these
  for(long c=0;c<count;c++){
    u64 mul=next()|1;
    double dG=(double)((GOLD*mul)<<8)/18446744073709551616.0, d1=(double)((mul)<<8)/18446744073709551616.0;
    if(dG<0.45||dG>0.55||d1<0.25||d1>0.75) continue; stage[0]++;
    if(rndfm(mul,16,1000,0,8000000,0)>0.019+1e-9) continue; stage[1]++;
    if(rndfm(mul,8,1000,0,8000000,0)>0.009+1e-9) continue; stage[2]++;
    if(rndfm(mul,16,1500,0,8000000,0)>0.045+1e-9) continue; stage[3]++;
    if(rndfm(mul,8,1500,0,8000000,0)>0.009+1e-9) continue; stage[4]++;
    if(rndfm(mul,16,16,0,8000000,0)>0.0625+1e-9) continue; stage[5]++;
    if(rndfm(mul,8,16,0,8000000,0)>0.0625+1e-9) continue; stage[6]++;
    if(rndfm(mul,16,24,0,8000000,0)>0.042+1e-3) continue; stage[7]++;
    if(rndfm(mul,8,24,0,8000000,0)>0.0+1e-9) continue; stage[8]++;
    if(rndhit(mul,16,16)>1e-9||rndhit(mul,8,16)>1e-9||rndhit(mul,16,24)>0.042+1e-3||rndhit(mul,8,24)>1e-9) continue;
    if(rndhit(mul,16,1000)>0.016+1e-9||rndhit(mul,16,1500)>0.024+1e-9||rndhit(mul,8,1000)>0.010+1e-9||rndhit(mul,8,1500)>0.009+1e-9) continue;
    double k2; if(rowins(mul,16,16,1,&k2)>0.07||k2>0.88+1e-9) continue; stage[9]++;
    if(rowins(mul,8,16,1,&k2)>0.07||k2>0.75+1e-9) continue; stage[10]++;
    double r16=rowk1(mul,16,100000,10); if(r16>0.15) continue; stage[11]++;
    double r8=rowk1(mul,8,100000,10); if(r8>0.807) continue; stage[12]++;
    double a16=rowk1(mul,16,1000,50), a8=rowk1(mul,8,1000,50); if(a16>0.767||a8>0.40) continue; stage[13]++;
    double w; if(spread(mul,16,&w)||spread(mul,8,&w)) continue; stage[14]++;
    printf("%016llx dG=%.3f d1=%.3f rh100k %.3f/%.3f rh1k %.3f/%.3f\n",(unsigned long long)mul,dG,d1,r16,r8,a16,a8); fflush(stdout); pass++;
  }
  fprintf(stderr,"searched %ld, passed %ld\n",count,pass); for(int i=0;i<20;i++) fprintf(stderr,"%ld ",stage[i]); fprintf(stderr,"\n"); return 0;
}
int main(int argc,char**argv){
  if(getenv("FMS")){ size_t sz=atol(getenv("FMS")); int W=atoi(getenv("W")?getenv("W"):"16");
    for(int i=1;i<argc;i++){ u64 mul=strtoull(argv[i],0,16); printf("%s W%d s=%zu",argv[i],W,sz); double sum=0;
      for(int j=0;j<10;j++){ double a=rndfm(mul,W,sz,0,8000000+j*7919,0), b=rndfm(mul,W,sz,100000000+j*104729,8000000,0); sum+=a+b; printf(" %.3f/%.3f",a,b);} printf(" mean %.4f\n",sum/20);} return 0; }
  if(getenv("OCC")){ size_t sz=atol(getenv("OCC")); int W=atoi(getenv("W")?getenv("W"):"16");
    for(int i=1;i<argc;i++){ u64 mul=strtoull(argv[i],0,16); T t; tinit(&t,W); for(size_t k=0;k<sz;k++) insert(&t,rotl8(((u64)k)*0x9e3779b97f4a7c15ULL*mul));
      { double Hs[6]; for(int k=1;k<=5;k++){ /* conditional entropy of cnt[g] given the k before, cyclic */
          static long ctx[1<<22][16]; static int used[1<<22]; memset(used,0,sizeof used); long keys[1<<16]; int nk=0; u64 Gm=t.G;
          for(u64 g=0;g<Gm;g++){ unsigned key=0; for(int j=1;j<=k;j++) key=key*16+t.cnt[(g+Gm-j)%Gm]; key&=(1<<22)-1; if(!used[key]){used[key]=1; memset(ctx[key],0,sizeof ctx[key]); if(nk<(1<<16)) keys[nk++]=key;} ctx[key][t.cnt[g]]++; }
          double H=0; for(int q=0;q<nk;q++){ long tot=0; for(int o=0;o<16;o++) tot+=ctx[keys[q]][o]; for(int o=0;o<16;o++) if(ctx[keys[q]][o]){ double p=(double)ctx[keys[q]][o]/tot; H-= ctx[keys[q]][o]*__builtin_log2(p);} }
          Hs[k]=H/Gm; }
        printf("%s W%d s=%zu H1..5 %.3f %.3f %.3f %.3f %.3f\n",argv[i],W,sz,Hs[1],Hs[2],Hs[3],Hs[4],Hs[5]); }
      long tr=0, hist[16]={0}, tr2=0; for(u64 g=0;g<t.G;g++){ hist[t.cnt[g]]++; if(g&&t.cnt[g]!=t.cnt[g-1]) tr++; if(g>1&&t.cnt[g]!=t.cnt[g-2]) tr2++; }
      printf("%s W%d G=%llu trans %.3f trans2 %.3f occ:",argv[i],W,(unsigned long long)t.G,(double)tr/t.G,(double)tr2/t.G); for(int o=0;o<16;o++) if(hist[o]) printf(" %d:%ld",o,hist[o]); printf("\n"); tfree(&t);} return 0; }
  if(getenv("OCCDUMP")){ size_t sz=atol(getenv("OCCDUMP")); int W=atoi(getenv("W")?getenv("W"):"16"); u64 mul=strtoull(argv[1],0,16);
    T t; tinit(&t,W); for(size_t k=0;k<sz;k++) insert(&t,rotl8(((u64)k)*0x9e3779b97f4a7c15ULL*mul)); for(u64 g=0;g<t.G;g++) putchar('a'+t.cnt[g]); putchar('\n'); return 0; }
  if(getenv("RNDGV")){ for(int i=1;i<argc;i++){ u64 mul=strtoull(argv[i],0,16); printf("%s",argv[i]);
      for(int W=16;W>=8;W-=8){ static const size_t rs[]={16,24,1000,1500}; printf(" | W%d",W);
        for(int q=0;q<4;q++){ double gv; double fm=rndfm(mul,W,rs[q],0,8000000,&gv); T t; tinit(&t,W); for(size_t k=0;k<rs[q];k++) insert(&t,rotl8(scat(k)*mul)); long ps=probesteps(&t); tfree(&t);
          printf(" %zu:%.3f/%.3f/%.3f/%.3f",rs[q],gv,fm,rndhit(mul,W,rs[q]),(double)ps/rs[q]); } }
      printf("\n"); } return 0; }
  if(getenv("LOTTO")){ long n=atol(getenv("LOTTO")); rng=7; static const size_t rs[]={16,24,1000,1500}; u64 M0=0x4b33a62ed433d4a3ULL;
    double m[2][4][4]; for(int w=0;w<2;w++) for(int q=0;q<4;q++){ double g; m[w][q][0]=rndfm(M0,w?8:16,rs[q],0,8000000,&g); m[w][q][1]=g; m[w][q][2]=rndhit(M0,w?8:16,rs[q]); m[w][q][3]=rnddisp(M0,w?8:16,rs[q]); }
    long pass[2][4][4]={0}, all=0;
    for(long c=0;c<n;c++){ u64 mul=next()|1; int ok=1;
      for(int w=0;w<2;w++) for(int q=0;q<4;q++){ double g; double v[4]; v[0]=rndfm(mul,w?8:16,rs[q],0,8000000,&g); v[1]=g; v[2]=rndhit(mul,w?8:16,rs[q]); v[3]=rnddisp(mul,w?8:16,rs[q]);
        for(int f=0;f<4;f++){ if(v[f]<=m[w][q][f]+1e-9) pass[w][q][f]++; else ok=0; } }
      all+=ok; }
    const char*fn[]={"fm","gv","hitfm","disp"};
    for(int w=0;w<2;w++) for(int q=0;q<4;q++){ printf("W%d s=%zu",w?8:16,rs[q]); for(int f=0;f<4;f++) printf(" %s<=%.3f: %.3f",fn[f],m[w][q][f],(double)pass[w][q][f]/n); printf("\n"); }
    printf("all %ld of %ld\n",all,n); return 0; }
  if(getenv("WALKS")){ for(int i=1;i<argc;i++){ u64 mul=strtoull(argv[i],0,16); printf("%s",argv[i]);
      for(int W=16;W>=8;W-=8){ printf(" | W%d",W); static const size_t ss[]={1000,100000,1000000,4000000}; for(int q=0;q<4;q++){ printf(" %zu:",ss[q]); for(int K=1;K<=4;K++) printf("%s%.3f",K>1?"/":"",walkmp(mul,W,ss[q],K)); } }
      printf("\n"); fflush(stdout);} return 0; }
  if(getenv("INSK")){ for(int i=1;i<argc;i++){ u64 mul=strtoull(argv[i],0,16); printf("%s",argv[i]);
      for(int W=16;W>=8;W-=8){ printf(" | W%d",W); static const size_t ss[]={16,1000,100000,1000000}; static const int ks[]={1,50,10,1}; for(int q=0;q<4;q++){ double k2; double k1=rowins(mul,W,ss[q],ks[q],&k2); printf(" %zu:%.3f/%.3f",ss[q],k1,k2);} }
      printf("\n"); } return 0; }
  if(getenv("RHK2")){ for(int i=1;i<argc;i++){ u64 mul=strtoull(argv[i],0,16); printf("%s",argv[i]);
      for(int W=16;W>=8;W-=8){ printf(" | W%d",W); static const size_t ss[]={1000,100000,1000000,4000000}; static const int ks[]={50,10,1,1}; for(int q=0;q<4;q++){ rowk1(mul,W,ss[q],ks[q]); double n=(double)ss[q]*ks[q]; printf(" %zu:%.3f/%.3f",ss[q],rh_k1/n,rh_k2/n);} }
      printf("\n"); fflush(stdout);} return 0; }
  if(getenv("INTROW")){ for(int i=1;i<argc;i++){ u64 mul=strtoull(argv[i],0,16); printf("%s",argv[i]);
      for(int W=16;W>=8;W-=8){ static const size_t ss[]={16,1000,100000,1000000}; printf(" | W%d",W); for(int q=0;q<4;q++){ double gv,fm,hf; introw(mul,W,ss[q],&gv,&fm,&hf); printf(" %zu:%.3f/%.3f/%.3f",ss[q],gv,fm,hf);} }
      printf("\n"); } return 0; }
  if(getenv("SEARCH3")){ long count=atol(getenv("SEARCH3")); rng=strtoull(argc>1?argv[1]:"1",0,16); long pass=0; int all=getenv("ALL")!=0;
    #define REJ(c) if((c)&&!all) continue
    for(long c=0;c<count;c++){ u64 mul= c<argc-2 ? strtoull(argv[c+2],0,16) : (next()|1);
      double dG=(double)((GOLD*mul)<<8)/18446744073709551616.0, d1=(double)((mul)<<8)/18446744073709551616.0;
      REJ(dG<0.45||dG>0.55||d1<0.25||d1>0.75);
      REJ(rndfm(mul,16,1000,0,8000000,0)>0.019+1e-9); REJ(rndfm(mul,8,1000,0,8000000,0)>0.009+1e-9);
      REJ(rndfm(mul,16,1500,0,8000000,0)>0.045+1e-9); REJ(rndfm(mul,8,1500,0,8000000,0)>0.009+1e-9);
      REJ(rndfm(mul,16,16,0,8000000,0)>0.0625+1e-9); REJ(rndfm(mul,8,16,0,8000000,0)>0.0625+1e-9);
      REJ(rndfm(mul,16,24,0,8000000,0)>0.042+1e-3); REJ(rndfm(mul,8,24,0,8000000,0)>1e-9);
      REJ(rndhit(mul,16,16)>1e-9||rndhit(mul,8,16)>1e-9||rndhit(mul,16,24)>0.042+1e-3||rndhit(mul,8,24)>1e-9);
      REJ(rndhit(mul,16,1000)>0.016+1e-9||rndhit(mul,16,1500)>0.024+1e-9||rndhit(mul,8,1000)>0.010+1e-9||rndhit(mul,8,1500)>0.009+1e-9);
      double k2,k2b; double i16=rowins(mul,16,16,1,&k2), i8=rowins(mul,8,16,1,&k2b); REJ(i16>0.07||k2>0.88+1e-9||i8>0.07||k2b>0.75+1e-9);
      double gv,fm,hf; int bad=0; static const size_t ss[]={16,1000,100000}; 
      for(int W=16;W>=8;W-=8) for(int q=0;q<3;q++){ introw(mul,W,ss[q],&gv,&fm,&hf); double mf=(W==16&&q==2)?0.288:0, mh=(W==16&&q==2)?0.438:0; if(gv>1.0005||fm>mf+0.005||hf>mh+0.005) bad=1; } REJ(bad);
      double w16=walkmp(mul,16,100000,2); REJ(w16>0.38);
      double v16=walkmp(mul,16,1000,12); REJ(v16>0.035);
      double r16=rowk1(mul,16,100000,10); REJ(r16>0.15);
      double a16=rowk1(mul,16,1000,50); REJ(a16>0.767);
      double w; int sp=spread(mul,16,&w)||spread(mul,8,&w); REJ(sp);
      double r8=rowk1(mul,8,100000,10), a8=rowk1(mul,8,1000,50);
      double m16=rowk1(mul,16,1000000,1); REJ(m16>0.6);
      int bad2=0; for(int W=16;W>=8;W-=8){ introw(mul,W,1000000,&gv,&fm,&hf); if(gv>1.0005||fm>0.005||hf>0.005) bad2=1; } REJ(bad2);
      double q16=rowk1(mul,16,4000000,1); REJ(q16>0.6);
      double m8=rowk1(mul,8,1000000,1), q8=rowk1(mul,8,4000000,1);
      printf("%016llx dG %.3f d1 %.3f ins16 %.2f/%.2f %.2f/%.2f rh(1k,100k,1m,4m) W16 %.3f %.3f %.3f %.3f W8 %.3f %.3f %.3f %.3f walk W16 %.3f %.3f W8 %.3f %.3f spread %d\n",(unsigned long long)mul,dG,d1,i16,k2,i8,k2b,a16,r16,m16,q16,a8,r8,m8,q8,w16,v16,walkmp(mul,8,100000,2),walkmp(mul,8,1000,12),sp); fflush(stdout); pass++; }
    fprintf(stderr,"searched %ld passed %ld\n",count,pass); return 0; }
  if(getenv("BASE")||getenv("VARY")){ long count=getenv("BASE")?atol(getenv("BASE")):(1L<<atoi(getenv("VBITS")?getenv("VBITS"):"17")); rng=strtoull(argc>1?argv[1]:"1",0,16); long pass=0;
    u64 ginv=GOLD; for(int it=0;it<6;it++) ginv*=2-GOLD*ginv;   /* GOLD * ginv == 1 */
    u64 base= getenv("VARY") ? strtoull(getenv("VARY"),0,16) : 0; int vbits=atoi(getenv("VBITS")?getenv("VBITS"):"17");
    for(long c=0;c<count;c++){
      u64 mul;
      if(getenv("VARY")) { if(c>=(1L<<vbits)) break; mul=ginv*((base*GOLD)^(u64)c); }
      else mul=next()|1;
      double dG=(double)((GOLD*mul)<<8)/18446744073709551616.0, d1=(double)((mul)<<8)/18446744073709551616.0;
      if(dG<0.45||dG>0.55) continue;
      if(getenv("VARY")){ /* the lottery: rows on random keys, the other strides */
        if(d1<0.25||d1>0.75) continue;
        if(rndfm(mul,16,1000,0,8000000,0)>0.019+1e-9) continue; if(rndfm(mul,8,1000,0,8000000,0)>0.009+1e-9) continue;
        if(rndfm(mul,16,1500,0,8000000,0)>0.045+1e-9) continue; if(rndfm(mul,8,1500,0,8000000,0)>0.009+1e-9) continue;
        if(rndfm(mul,16,16,0,8000000,0)>0.0625+1e-9) continue; if(rndfm(mul,8,16,0,8000000,0)>0.0625+1e-9) continue;
        if(rndfm(mul,16,24,0,8000000,0)>0.042+1e-3) continue; if(rndfm(mul,8,24,0,8000000,0)>1e-9) continue;
        if(rndhit(mul,16,16)>1e-9||rndhit(mul,8,16)>1e-9||rndhit(mul,16,24)>0.042+1e-3||rndhit(mul,8,24)>1e-9) continue;
        if(rndhit(mul,16,1000)>0.016+1e-9||rndhit(mul,16,1500)>0.024+1e-9||rndhit(mul,8,1000)>0.010+1e-9||rndhit(mul,8,1500)>0.009+1e-9) continue;
        if(rndworse(mul)) continue;
      }
      double k2,k2b; double i16=rowins(mul,16,16,1,&k2), i8=rowins(mul,8,16,1,&k2b); if(i16>0.07||k2>0.88+1e-9||i8>0.07||k2b>0.75+1e-9) continue;
      double gv,fm,hf; int bad=0; static const size_t ss[]={16,1000,100000};
      for(int W=16;W>=8;W-=8) for(int q=0;q<3;q++){ introw(mul,W,ss[q],&gv,&fm,&hf); double mf=(W==16&&q==2)?0.288:0, mh=(W==16&&q==2)?0.438:0; if(gv>1.0005||fm>mf+0.005||hf>mh+0.005) bad=1; } if(bad) continue;
      double r16=rowk1(mul,16,100000,10); if(r16>0.15) continue;
      double a16=rowk1(mul,16,1000,50); if(a16>0.767) continue;
      double w16=walkmp(mul,16,100000,2); if(w16>0.38) continue;
      double v16=walkmp(mul,16,1000,12); if(v16>0.035) continue;
      double r8=rowk1(mul,8,100000,10), a8=rowk1(mul,8,1000,50); if(r8>0.85||a8>0.45) continue;
      if(getenv("VARY")){ double w; if(spread(mul,16,&w)||spread(mul,8,&w)) continue; }
      double m16=rowk1(mul,16,1000000,1); if(m16>0.6) continue;
      int bad2=0; for(int W=16;W>=8;W-=8){ introw(mul,W,1000000,&gv,&fm,&hf); if(gv>1.0005||fm>0.005||hf>0.005) bad2=1; } if(bad2) continue;
      double q16=rowk1(mul,16,4000000,1); if(q16>0.6) continue;
      double m8=rowk1(mul,8,1000000,1), q8=rowk1(mul,8,4000000,1);
      printf("%016llx dG %.3f d1 %.3f ins16 %.2f/%.2f %.2f/%.2f rh(1k,100k,1m,4m) W16 %.3f %.3f %.3f %.3f W8 %.3f %.3f %.3f %.3f walk W16 %.3f %.3f W8 %.3f %.3f\n",(unsigned long long)mul,dG,d1,i16,k2,i8,k2b,a16,r16,m16,q16,a8,r8,m8,q8,w16,v16,walkmp(mul,8,100000,2),walkmp(mul,8,1000,12)); fflush(stdout); pass++; }
    fprintf(stderr,"searched %ld passed %ld\n",count,pass); return 0; }
  if(getenv("SEARCH2")){ long count=atol(getenv("SEARCH2")); rng=strtoull(argc>1?argv[1]:"1",0,16); long pass=0;
    for(long c=0;c<count;c++){ u64 mul= c<argc-2 ? strtoull(argv[c+2],0,16) : (next()|1);
      double dG=(double)((GOLD*mul)<<8)/18446744073709551616.0, d1=(double)((mul)<<8)/18446744073709551616.0;
      if(dG<0.45||dG>0.55||d1<0.25||d1>0.75) continue;
      double f1=rndfm(mul,16,1000,0,8000000,0); if(f1>0.019+1e-9) continue;
      double k2,k2b; if(rowins(mul,16,16,1,&k2)>0.07||k2>0.88+1e-9) continue; if(rowins(mul,8,16,1,&k2b)>0.07||k2b>0.75+1e-9) continue;
      double r16=rowk1(mul,16,100000,10); if(r16>0.15) continue;
      double a16=rowk1(mul,16,1000,50); if(a16>0.767) continue;
      double w; if(spread(mul,16,&w)||spread(mul,8,&w)) continue;
      double r8=rowk1(mul,8,100000,10), a8=rowk1(mul,8,1000,50);
      printf("%016llx dG %.3f d1 %.3f rh100k %.3f %.3f rh1k %.3f %.3f",(unsigned long long)mul,dG,d1,r16,r8,a16,a8);
      static const size_t rs[]={16,24,1000,1500}; for(int W=16;W>=8;W-=8){ printf(" | W%d miss",W); for(int q=0;q<4;q++) printf(" %.3f",rndfm(mul,W,rs[q],0,8000000,0)); printf(" hit"); for(int q=0;q<4;q++) printf(" %.3f",rndhit(mul,W,rs[q])); printf(" H5 %.3f %.3f",H5(mul,W,1000),H5(mul,W,100000)); }
      printf("\n"); fflush(stdout); pass++; }
    fprintf(stderr,"searched %ld passed %ld\n",count,pass); return 0; }
  if(getenv("SEARCH")) return search(atol(getenv("SEARCH")), strtoull(argc>1?argv[1]:"1",0,16));
  int mode_full = getenv("FULL")!=0;
  for(int i=1;i<argc;i++){
    u64 mul=strtoull(argv[i],0,16);
    double dG=(double)((GOLD*mul)<<8)/18446744073709551616.0, d1=(double)((mul)<<8)/18446744073709551616.0;
    printf("%s dG=%.3f d1=%.3f",argv[i],dG,d1);
    for(int W=16;W>=8;W-=8){
      double wsp; int bad=spread(mul,W,&wsp);
      double k2; double i16=rowins(mul,W,16,1,&k2);
      printf(" | W%d spread %d/%.3f ins16 %.2f/%.2f",W,bad,wsp,i16,k2);
      printf(" rh1k %.3f rh100k %.3f",rowk1(mul,W,1000,50),rowk1(mul,W,100000,10));
      if(mode_full) printf(" rh1m %.3f rh4m %.3f",rowk1(mul,W,1000000,1),rowk1(mul,W,4000000,1));
      printf(" fm16 %.3f fm24 %.3f fm1k %.3f fm1.5k %.3f",rndfm(mul,W,16,0,8000000,0),rndfm(mul,W,24,0,8000000,0),rndfm(mul,W,1000,0,8000000,0),rndfm(mul,W,1500,0,8000000,0));
    }
    printf("\n"); fflush(stdout);
  }
}
