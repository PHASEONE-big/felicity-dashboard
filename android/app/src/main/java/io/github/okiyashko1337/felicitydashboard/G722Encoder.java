package io.github.okiyashko1337.felicitydashboard;

/*
 * ITU G.722 64 kbit/s encoder adapted to Java from Android Open Source
 * Project's embdrv/g722/g722_encode.cc. The original implementation by
 * Steve Underwood is in the public domain and is based partly on CMU Speech
 * Group code (1993).
 */
final class G722Encoder {
    private static final int[] Q6={0,35,72,110,150,190,233,276,323,370,422,473,530,587,650,714,786,858,940,1023,1121,1219,1339,1458,1612,1765,1980,2195,2557,2919,0,0};
    private static final int[] ILN={0,63,62,31,30,29,28,27,26,25,24,23,22,21,20,19,18,17,16,15,14,13,12,11,10,9,8,7,6,5,4,0};
    private static final int[] ILP={0,61,60,59,58,57,56,55,54,53,52,51,50,49,48,47,46,45,44,43,42,41,40,39,38,37,36,35,34,33,32,0};
    private static final int[] WL={-60,-30,58,172,334,538,1198,3042};
    private static final int[] RL42={0,7,6,5,4,3,2,1,7,6,5,4,3,2,1,0};
    private static final int[] ILB={2048,2093,2139,2186,2233,2282,2332,2383,2435,2489,2543,2599,2656,2714,2774,2834,2896,2960,3025,3091,3158,3228,3298,3371,3444,3520,3597,3676,3756,3838,3922,4008};
    private static final int[] QM4={0,-20456,-12896,-8968,-6288,-4240,-2584,-1200,20456,12896,8968,6288,4240,2584,1200,0};
    private static final int[] QM2={-7408,-1616,7408,1616};
    private static final int[] QMF={3,-11,12,32,-210,951,3876,-805,362,-156,53,-11};
    private static final int[] IHN={0,1,0},IHP={0,3,2},WH={0,-214,798},RH2={2,1,2,1};
    private final Band[] band={new Band(),new Band()};
    private final int[] x=new int[24];

    G722Encoder(){band[0].det=32;band[1].det=8;}

    int encode(short[] pcm,int offset,int length,byte[] encoded){
        int end=offset+(length&~1),out=0;
        for(int j=offset;j<end;){
            System.arraycopy(x,2,x,0,22);x[22]=pcm[j++];x[23]=pcm[j++];
            int even=0,odd=0;for(int i=0;i<12;i++){odd+=x[2*i]*QMF[i];even+=x[2*i+1]*QMF[11-i];}
            int low=(even+odd)>>14,high=(even-odd)>>14;

            int error=sat(low-band[0].s),magnitude=error>=0?error:-(error+1),i;
            for(i=1;i<30;i++)if(magnitude<((Q6[i]*band[0].det)>>12))break;
            int lowCode=error<0?ILN[i]:ILP[i],ril=lowCode>>2;
            int lowDelta=(band[0].det*QM4[ril])>>15;
            int nb=((band[0].nb*127)>>7)+WL[RL42[ril]];band[0].nb=Math.max(0,Math.min(18432,nb));
            int wd1=(band[0].nb>>6)&31,wd2=8-(band[0].nb>>11),wd3=wd2<0?ILB[wd1]<<-wd2:ILB[wd1]>>wd2;band[0].det=wd3<<2;
            block4(band[0],lowDelta);

            error=sat(high-band[1].s);magnitude=error>=0?error:-(error+1);
            int threshold=(564*band[1].det)>>12,mih=magnitude>=threshold?2:1,highCode=error<0?IHN[mih]:IHP[mih];
            int highDelta=(band[1].det*QM2[highCode])>>15;
            nb=((band[1].nb*127)>>7)+WH[RH2[highCode]];band[1].nb=Math.max(0,Math.min(22528,nb));
            wd1=(band[1].nb>>6)&31;wd2=10-(band[1].nb>>11);wd3=wd2<0?ILB[wd1]<<-wd2:ILB[wd1]>>wd2;band[1].det=wd3<<2;
            block4(band[1],highDelta);
            encoded[out++]=(byte)((highCode<<6)|lowCode);
        }
        return out;
    }

    private static void block4(Band b,int value){
        b.d[0]=value;b.r[0]=sat(b.s+value);b.p[0]=sat(b.sz+value);
        int sign0=b.p[0]>>15,sign1=b.p[1]>>15,sign2=b.p[2]>>15;
        int wd1=sat(b.a[1]<<2),wd2=sign0==sign1?-wd1:wd1;if(wd2>32767)wd2=32767;
        int ap2=(wd2>>7)+(sign0==sign2?128:-128)+((b.a[2]*32512)>>15);b.ap[2]=Math.max(-12288,Math.min(12288,ap2));
        wd1=sign0==sign1?192:-192;wd2=(b.a[1]*32640)>>15;int ap1=sat(wd1+wd2),wd3=sat(15360-b.ap[2]);b.ap[1]=Math.max(-wd3,Math.min(wd3,ap1));
        wd1=value==0?0:128;int sz=0;for(int i=1;i<7;i++){wd2=(b.d[i]>>15)==(value>>15)?wd1:-wd1;wd3=(b.b[i]*32640)>>15;b.bp[i]=sat(wd2+wd3);}
        for(int i=6;i>0;i--){b.d[i]=b.d[i-1];b.b[i]=b.bp[i];wd1=sat(b.d[i]+b.d[i]);sz+=(b.b[i]*wd1)>>15;}b.sz=sat(sz);
        for(int i=2;i>0;i--){b.r[i]=b.r[i-1];b.p[i]=b.p[i-1];b.a[i]=b.ap[i];}
        wd1=(b.a[1]*sat(b.r[1]+b.r[1]))>>15;wd2=(b.a[2]*sat(b.r[2]+b.r[2]))>>15;b.sp=sat(wd1+wd2);b.s=sat(b.sp+b.sz);
    }
    private static int sat(int value){return value>32767?32767:value< -32768?-32768:value;}
    private static final class Band{int s,sp,sz,nb,det;final int[] r=new int[3],a=new int[3],ap=new int[3],p=new int[3],d=new int[7],b=new int[7],bp=new int[7];}
}
