package io.github.okiyashko1337.felicitydashboard;

import org.junit.Test;
import static org.junit.Assert.*;

public final class CameraCatalogTest {
    @Test public void unknownCameraUsesNeutralMainFallback(){assertArrayEquals(new int[]{1920,1080},CameraCatalog.fallbackVideoSize(new CameraCatalog.Camera("camera","Kitchen hik-AI","host"),true));}
    @Test public void smallScreenFallbackUsesSubProfileDimensions(){CameraCatalog.Camera camera=new CameraCatalog.Camera("entrance","Entrance indoor","host","source","main","sub","rtsp://main","rtsp://sub","main-r","sub-r",2688,1520,640,480,0,false);assertArrayEquals(new int[]{640,480},CameraCatalog.fallbackVideoSize(camera,true));assertArrayEquals(new int[]{2688,1520},CameraCatalog.fallbackVideoSize(camera,false));}
    @Test public void displayAspectComesFromMainProfileNotSubstream(){CameraCatalog.Camera camera=new CameraCatalog.Camera("token","Kitchen hik-AI","host","token","main","sub","rtsp://main","rtsp://sub","main-r","sub-r",3840,2160,0,false);assertEquals(16f/9f,CameraCatalog.mainAspect(camera),0.001f);}
    @Test public void corridorRotationSwapsMainAspect(){CameraCatalog.Camera camera=new CameraCatalog.Camera("token","Corridor","host","token","main","sub","rtsp://main","rtsp://sub","main-r","sub-r",1920,1080,90,false);assertEquals(9f/16f,CameraCatalog.mainAspect(camera),0.001f);}
    @Test public void magnoliaUsesPortraitDarWithoutRotatingPixels(){CameraCatalog.Camera camera=new CameraCatalog.Camera("magnolia","Magnolia FTW","host","JasU1Wn1xB-9c756e34113e-0","main","sub","rtsp://main","rtsp://sub","main-r","sub-r",3840,2160,0,false);assertTrue(camera.corridor);assertEquals(0,camera.rotationDegrees);assertEquals(9f/16f,CameraCatalog.mainAspect(camera),0.001f);}
    @Test public void entranceIndoorUsesPortraitDarWithoutRotatingPixels(){CameraCatalog.Camera camera=new CameraCatalog.Camera("entrance","Entrance indoor","host","RufpaSMY9J-VideoSource_1","main","sub","rtsp://main","rtsp://sub","main-r","sub-r",2688,1520,0,false);assertTrue(camera.corridor);assertEquals(0,camera.rotationDegrees);assertEquals(9f/16f,CameraCatalog.mainAspect(camera),0.001f);}
    @Test public void regularCameraKeepsLandscapeAspect(){CameraCatalog.Camera camera=new CameraCatalog.Camera("kitchen","Kitchen hik","host","kitchen-source","main","sub","rtsp://main","rtsp://sub","main-r","sub-r",3840,2160,0,false);assertFalse(camera.corridor);assertEquals(16f/9f,CameraCatalog.mainAspect(camera),0.001f);}
    @Test public void archiveTextureLetterboxesLandscapeLikeLive(){float[] fit=CameraCatalog.textureFit(16f/9f,1920,756);assertEquals(.7f,fit[0],.01f);assertEquals(1f,fit[1],.001f);}
    @Test public void archiveTextureLetterboxesPortraitLikeLive(){float[] fit=CameraCatalog.textureFit(9f/16f,1920,756);assertEquals(.221f,fit[0],.01f);assertEquals(1f,fit[1],.001f);}
}
