package io.github.okiyashko1337.felicitydashboard;

import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.StateListDrawable;
import android.view.Gravity;
import android.widget.Button;

final class ControlStyle {
    private ControlStyle() {}

    static void apply(Button button, boolean redNight) {
        int accent=redNight?0xffff5a46:0xff59ded1;
        int normal=redNight?0xff3b0b08:0xff123d37;
        int pressed=redNight?0xff741710:0xff24675d;
        StateListDrawable states=new StateListDrawable();
        states.addState(new int[]{android.R.attr.state_pressed},shape(pressed,accent));
        states.addState(new int[]{android.R.attr.state_focused},shape(pressed,accent));
        states.addState(new int[]{},shape(normal,0xff376b64));
        button.setBackground(states);
        button.setAllCaps(false);
        button.setGravity(Gravity.CENTER);
        button.setMinWidth(0);button.setMinHeight(0);
        button.setPadding(6,0,6,0);
        button.setElevation(3);
    }

    private static GradientDrawable shape(int fill,int stroke) {
        GradientDrawable result=new GradientDrawable();
        result.setColor(fill);result.setCornerRadius(11);result.setStroke(1,stroke);
        return result;
    }
}
