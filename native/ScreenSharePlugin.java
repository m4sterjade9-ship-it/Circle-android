package com.banaagjade.circle;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.util.DisplayMetrics;

import androidx.activity.result.ActivityResult;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.annotation.CapacitorPlugin;

import org.webrtc.DefaultVideoDecoderFactory;
import org.webrtc.DefaultVideoEncoderFactory;
import org.webrtc.EglBase;
import org.webrtc.IceCandidate;
import org.webrtc.MediaConstraints;
import org.webrtc.MediaStream;
import org.webrtc.PeerConnection;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.RtpParameters;
import org.webrtc.RtpSender;
import org.webrtc.ScreenCapturerAndroid;
import org.webrtc.SdpObserver;
import org.webrtc.SessionDescription;
import org.webrtc.SurfaceTextureHelper;
import org.webrtc.VideoSource;
import org.webrtc.VideoTrack;
import org.webrtc.DataChannel;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Captures the Android screen with MediaProjection and sends it to the other person over its own
 * WebRTC connection (hardware encoded, up to 1080p / 60 fps). JavaScript does the signalling.
 * Events go to the page as window.__ssEvent({t:'sdp'|'ice'|'stopped'|'error', ...}).
 */
@CapacitorPlugin(name = "ScreenShare")
public class ScreenSharePlugin extends Plugin {
    private EglBase egl;
    private PeerConnectionFactory factory;
    private PeerConnection pc;
    private ScreenCapturerAndroid capturer;
    private SurfaceTextureHelper helper;
    private VideoSource source;
    private VideoTrack track;
    private boolean remoteSet = false;
    private boolean stopping = false;
    private final List<IceCandidate> pending = new ArrayList<>();

    private static class Sdp implements SdpObserver {
        @Override public void onCreateSuccess(SessionDescription d) {}
        @Override public void onSetSuccess() {}
        @Override public void onCreateFailure(String e) {}
        @Override public void onSetFailure(String e) {}
    }

    private void emit(String t, JSObject extra) {
        JSObject o = extra != null ? extra : new JSObject();
        o.put("t", t);
        final String js = "window.__ssEvent&&window.__ssEvent(" + o.toString() + ")";
        try {
            getBridge().getWebView().post(() -> getBridge().getWebView().evaluateJavascript(js, null));
        } catch (Throwable ignored) {}
    }

    @PluginMethod
    public void start(PluginCall call) {
        stopInternal();
        if (Build.VERSION.SDK_INT >= 33
                && getActivity().checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            getActivity().requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 9001);
        }
        MediaProjectionManager m = (MediaProjectionManager) getContext().getSystemService(Context.MEDIA_PROJECTION_SERVICE);
        startActivityForResult(call, m.createScreenCaptureIntent(), "onProjection");
    }

    @ActivityCallback
    private void onProjection(PluginCall call, ActivityResult result) {
        if (call == null) return;
        if (result.getResultCode() != Activity.RESULT_OK || result.getData() == null) {
            call.reject("cancelled");
            return;
        }
        final Intent data = result.getData();
        ScreenShareService.onReady = () -> begin(call, data);
        Intent s = new Intent(getContext(), ScreenShareService.class);
        if (Build.VERSION.SDK_INT >= 26) getContext().startForegroundService(s);
        else getContext().startService(s);
    }

    private void begin(PluginCall call, Intent data) {
        try {
            Context ctx = getContext().getApplicationContext();
            List<PeerConnection.IceServer> ice = new ArrayList<>();
            JSArray arr = call.getArray("ice");
            if (arr != null) {
                for (int i = 0; i < arr.length(); i++) {
                    ice.add(PeerConnection.IceServer.builder(arr.getString(i)).createIceServer());
                }
            }

            PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(ctx).createInitializationOptions());
            egl = EglBase.create();
            factory = PeerConnectionFactory.builder()
                    .setVideoEncoderFactory(new DefaultVideoEncoderFactory(egl.getEglBaseContext(), true, true))
                    .setVideoDecoderFactory(new DefaultVideoDecoderFactory(egl.getEglBaseContext()))
                    .createPeerConnectionFactory();

            capturer = new ScreenCapturerAndroid(data, new MediaProjection.Callback() {
                @Override public void onStop() {
                    if (!stopping) {
                        emit("stopped", null);
                        stopInternal();
                    }
                }
            });
            helper = SurfaceTextureHelper.create("circle-screen", egl.getEglBaseContext());
            source = factory.createVideoSource(true);
            capturer.initialize(helper, ctx, source.getCapturerObserver());

            // real screen size, scaled down to fit 1920x1080 (keeps the shape, even numbers)
            DisplayMetrics dm = new DisplayMetrics();
            getActivity().getWindowManager().getDefaultDisplay().getRealMetrics(dm);
            int w = dm.widthPixels, h = dm.heightPixels;
            double sc = Math.min(1.0, Math.min(1920.0 / Math.max(w, h), 1080.0 / Math.min(w, h)));
            w = ((int) (w * sc)) & ~1;
            h = ((int) (h * sc)) & ~1;
            capturer.startCapture(w, h, 60);

            track = factory.createVideoTrack("screen", source);
            PeerConnection.RTCConfiguration cfg = new PeerConnection.RTCConfiguration(ice);
            cfg.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
            pc = factory.createPeerConnection(cfg, new PeerConnection.Observer() {
                @Override public void onSignalingChange(PeerConnection.SignalingState s) {}
                @Override public void onIceConnectionChange(PeerConnection.IceConnectionState s) {}
                @Override public void onIceConnectionReceivingChange(boolean b) {}
                @Override public void onIceGatheringChange(PeerConnection.IceGatheringState s) {}
                @Override public void onIceCandidate(IceCandidate c) {
                    JSObject cand = new JSObject();
                    cand.put("candidate", c.sdp);
                    cand.put("sdpMid", c.sdpMid);
                    cand.put("sdpMLineIndex", c.sdpMLineIndex);
                    JSObject o = new JSObject();
                    o.put("c", cand);
                    emit("ice", o);
                }
                @Override public void onIceCandidatesRemoved(IceCandidate[] c) {}
                @Override public void onAddStream(MediaStream s) {}
                @Override public void onRemoveStream(MediaStream s) {}
                @Override public void onDataChannel(DataChannel d) {}
                @Override public void onRenegotiationNeeded() {}
            });

            RtpSender sender = pc.addTrack(track, Collections.singletonList("screen"));
            try {
                RtpParameters p = sender.getParameters();
                for (RtpParameters.Encoding e : p.encodings) {
                    e.maxBitrateBps = 10000000;
                    e.maxFramerate = 60;
                    e.scaleResolutionDownBy = 1.0;
                }
                p.degradationPreference = RtpParameters.DegradationPreference.MAINTAIN_FRAMERATE;
                sender.setParameters(p);
            } catch (Throwable ignored) {}

            pc.createOffer(new Sdp() {
                @Override public void onCreateSuccess(final SessionDescription d) {
                    pc.setLocalDescription(new Sdp() {
                        @Override public void onSetSuccess() {
                            JSObject o = new JSObject();
                            o.put("sdp", d.description);
                            emit("sdp", o);
                        }
                    }, d);
                }
                @Override public void onCreateFailure(String e) {
                    JSObject o = new JSObject();
                    o.put("m", e);
                    emit("error", o);
                }
            }, new MediaConstraints());

            JSObject r = new JSObject();
            r.put("width", w);
            r.put("height", h);
            call.resolve(r);
        } catch (Throwable t) {
            stopInternal();
            call.reject(String.valueOf(t.getMessage()));
        }
    }

    @PluginMethod
    public void setAnswer(PluginCall call) {
        try {
            if (pc != null) {
                pc.setRemoteDescription(new Sdp() {
                    @Override public void onSetSuccess() {
                        remoteSet = true;
                        for (IceCandidate c : pending) pc.addIceCandidate(c);
                        pending.clear();
                    }
                }, new SessionDescription(SessionDescription.Type.ANSWER, call.getString("sdp")));
            }
            call.resolve();
        } catch (Throwable t) {
            call.reject(String.valueOf(t.getMessage()));
        }
    }

    @PluginMethod
    public void addIce(PluginCall call) {
        try {
            if (pc != null) {
                Integer idx = call.getInt("sdpMLineIndex", 0);
                IceCandidate c = new IceCandidate(call.getString("sdpMid"), idx == null ? 0 : idx, call.getString("candidate"));
                if (remoteSet) pc.addIceCandidate(c);
                else pending.add(c);
            }
            call.resolve();
        } catch (Throwable t) {
            call.resolve();
        }
    }

    @PluginMethod
    public void stop(PluginCall call) {
        stopInternal();
        call.resolve();
    }

    private synchronized void stopInternal() {
        if (stopping) return;
        stopping = true;
        try { if (capturer != null) { capturer.stopCapture(); capturer.dispose(); } } catch (Throwable ignored) {}
        try { if (pc != null) pc.close(); } catch (Throwable ignored) {}
        try { if (track != null) track.dispose(); } catch (Throwable ignored) {}
        try { if (source != null) source.dispose(); } catch (Throwable ignored) {}
        try { if (helper != null) helper.dispose(); } catch (Throwable ignored) {}
        try { if (pc != null) pc.dispose(); } catch (Throwable ignored) {}
        try { if (factory != null) factory.dispose(); } catch (Throwable ignored) {}
        try { if (egl != null) egl.release(); } catch (Throwable ignored) {}
        capturer = null; pc = null; track = null; source = null; helper = null; factory = null; egl = null;
        remoteSet = false;
        pending.clear();
        try { getContext().stopService(new Intent(getContext(), ScreenShareService.class)); } catch (Throwable ignored) {}
        stopping = false;
    }
}
