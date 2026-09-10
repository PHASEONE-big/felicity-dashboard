package io.github.okiyashko1337.felicitydashboard;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import org.junit.Test;

public final class G722EncoderTest {
    @Test public void producesOneCodewordForTwoPcmSamples(){short[] pcm=new short[320];byte[] encoded=new byte[160];assertEquals(160,new G722Encoder().encode(pcm,0,pcm.length,encoded));}
    @Test public void roundTripPreservesNonSilentSignal(){short[] source=new short[3200];for(int i=0;i<source.length;i++)source[i]=(short)(10000*Math.sin(2*Math.PI*440*i/16000.0));byte[] encoded=new byte[source.length/2];assertEquals(encoded.length,new G722Encoder().encode(source,0,source.length,encoded));short[] decoded=new short[source.length];assertEquals(decoded.length,new G722Decoder().decode(encoded,0,encoded.length,decoded));long energy=0;for(int i=320;i<decoded.length;i++)energy+=(long)decoded[i]*decoded[i];assertTrue(energy>100000000L);}
}
