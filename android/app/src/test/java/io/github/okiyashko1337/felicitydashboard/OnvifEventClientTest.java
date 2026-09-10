package io.github.okiyashko1337.felicitydashboard;

import org.junit.Test;
import java.util.List;
import static org.junit.Assert.*;

public final class OnvifEventClientTest {
    private static OnvifEventClient client(){return new OnvifEventClient("host","user","password",new OnvifEventClient.Listener(){public void onListening(){}public void onEvent(String topic,String sourceToken){}public void onError(String error){}});}
    private static OnvifEventClient.Notification ring(String operation,boolean active){return new OnvifEventClient.Notification("tns1:RuleEngine/RingDetector",operation,active,true);}

    @Test public void acceptsRisingEdgeAndSuppressesImmediateDuplicate(){
        OnvifEventClient c=client();
        assertFalse(c.acceptRing(ring("Initialized",false),1_000));
        assertTrue(c.acceptRing(ring("Changed",true),2_000));
        assertFalse(c.acceptRing(ring("Changed",true),3_000));
    }

    @Test public void acceptsNextPressAfterRelease(){
        OnvifEventClient c=client();
        assertTrue(c.acceptRing(ring("Changed",true),1_000));
        assertFalse(c.acceptRing(ring("Changed",false),2_000));
        assertTrue(c.acceptRing(ring("Changed",true),3_000));
    }

    @Test public void recoversWhenReleaseEventWasLost(){
        OnvifEventClient c=client();
        assertTrue(c.acceptRing(ring("Changed",true),1_000));
        assertTrue(c.acceptRing(ring("Changed",true),10_000));
    }

    @Test public void acceptsOnvifStateSamplesWithoutPropertyOperation(){
        OnvifEventClient c=client();
        assertFalse(c.acceptRing(ring("",false),1_000));
        assertTrue(c.acceptRing(ring("",true),2_000));
        assertFalse(c.acceptRing(ring("",true),3_000));
        assertFalse(c.acceptRing(ring("",false),4_000));
        assertTrue(c.acceptRing(ring("",true),5_000));
    }

    @Test public void parsesRingFieldsAndSingleQuotedOperation(){
        String xml="<wsnt:NotificationMessage><wsnt:Topic>tns1:RuleEngine/tnsrecorder:RingDetector/Detection</wsnt:Topic>"
                +"<tt:Message PropertyOperation='Changed'><tt:Source><tt:SimpleItem Name='VideoSourceToken' Value='private-token'/></tt:Source>"
                +"<tt:Data><tt:SimpleItem Name='State' Value='pressed'/></tt:Data></tt:Message></wsnt:NotificationMessage>";
        List<OnvifEventClient.Notification> parsed=OnvifEventClient.parseNotifications(xml);
        assertEquals(1,parsed.size());
        OnvifEventClient.Notification event=parsed.get(0);
        assertEquals("Changed",event.operation);
        assertTrue(event.active);
        assertTrue(event.valueKnown);
        assertEquals("private-token",event.sourceToken);
        assertEquals("VideoSourceToken,State=pressed",event.details);
    }

    @Test public void acceptsObservedOnvifDetectedFalseToTrueTransition(){
        String prefix="<wsnt:NotificationMessage><wsnt:Topic>tns1:RuleEngine/tnsrecorder:RingDetector/Detection</wsnt:Topic><tt:Message>"
                +"<tt:Source><tt:SimpleItem Name=\"VideoSourceToken\" Value=\"token\"/><tt:SimpleItem Name=\"Rule\" Value=\"ring-rule\"/></tt:Source><tt:Data>";
        String suffix="</tt:Data></tt:Message></wsnt:NotificationMessage>";
        OnvifEventClient.Notification idle=OnvifEventClient.parseNotifications(prefix+"<tt:SimpleItem Name=\"Detected\" Value=\"false\"/>"+suffix).get(0);
        OnvifEventClient.Notification pressed=OnvifEventClient.parseNotifications(prefix+"<tt:SimpleItem Name=\"Detected\" Value=\"true\"/>"+suffix).get(0);
        OnvifEventClient c=client();
        assertFalse(c.acceptRing(idle,1_000));
        assertTrue(c.acceptRing(pressed,2_000));
        assertFalse(c.acceptRing(pressed,3_000));
        assertEquals("VideoSourceToken,Rule,Detected=true",pressed.details);
        assertEquals("token",pressed.sourceToken);
    }
}
