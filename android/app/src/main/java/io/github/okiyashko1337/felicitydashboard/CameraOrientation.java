package io.github.okiyashko1337.felicitydashboard;

import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;

final class CameraOrientation {
    private CameraOrientation(){}
    static void apply(FrameLayout container,View view,CameraCatalog.Camera camera){
        container.addOnLayoutChangeListener((v,l,t,r,b,oldL,oldT,oldR,oldB)->layout(container,view,camera));
        container.post(()->layout(container,view,camera));
    }
    private static void layout(FrameLayout container,View view,CameraCatalog.Camera camera){
        int rotation=CameraCatalog.displayRotation(camera);
        int width=container.getWidth(),height=container.getHeight();if(width<1||height<1)return;
        FrameLayout.LayoutParams params=(FrameLayout.LayoutParams)view.getLayoutParams();
        if(rotation==90||rotation==270){params.width=height;params.height=Math.max(1,Math.round(height/CameraCatalog.playerAspect(camera)));}else{params.width=FrameLayout.LayoutParams.MATCH_PARENT;params.height=FrameLayout.LayoutParams.MATCH_PARENT;}
        params.gravity=Gravity.CENTER;view.setLayoutParams(params);view.setRotation(rotation);
    }
}
