#import "TestViewController.h"
#import <GLKit/GLKit.h>
@import AVFoundation;

#include <owr/owr.h>
#include <owr/owr_local.h>
#include <owr/owr_payload.h>
#include <owr/owr_video_payload.h>
#include <owr/owr_audio_payload.h>
#include <owr/owr_video_renderer.h>
#include <owr/owr_audio_renderer.h>
#include <owr/owr_window_registry.h>
#include <owr/owr_transport_agent.h>
#include <owr/owr_media_session.h>

#include <gst/gst.h>

#define OWR_VIEW_TAG "owr-view"

@interface TestViewController ()

@property (weak) IBOutlet GLKView *owrView;

@end

@implementation TestViewController

// Workaround for https://github.com/EricssonResearch/openwebrtc/issues/225
#define OWR_INIT_WITH_MAIN_CONTEXT

// Whether to render the local view (before sending)
// #define RENDER_SELF_VIEW

// Define to use the OPUS codec (48000kHz)
// Undefine to use aLaw PCM (8000kHz), e.g. to test CPU load without OPUS encoding/decoding overhead
#define OPUS

// Define to disable TLS, e.g. to test CPU load without crypto overhead.
#define DISABLE_DTLS

// Define this to perform the normal send-receive loopback over TCP
// Undefine to test "self-view" performance and related bugs without dealing
// with the transport pipeline and codecs bugs / performance.
#define TEST_LOOPBACK

// Renders either self-view video or loopback (encoded and decoded) video.
OwrVideoRenderer *video_renderer = NULL;

// Renders either self-view audio or loopback (encoded and decoded) audio.
OwrAudioRenderer *audio_renderer = NULL;

OwrMediaSource *audio_source = NULL, *video_source = NULL;

// Sessions for sending and receiving video in loopback mode
#ifdef TEST_LOOPBACK
OwrMediaSession
    *recv_session_audio = NULL,
    *recv_session_video = NULL,
    *send_session_audio = NULL,
    *send_session_video = NULL;

OwrTransportAgent
    *send_transport_agent,
    *recv_transport_agent;
#endif

// Disabling this flag keeps only audio support.
// This is useful for testing purely audio bugs and performance.
const bool USE_VIDEO = false;

int video_width, video_height;
float transmit_frame_rate, render_frame_rate;
// The audio sample rate for the selected code.
// Might be different from the hardware sample rate.
guint audio_codec_rate;
// The number of channels for the codec.
guint audio_codec_channels;
OwrCodecType audio_codec_type;

// Instead of using owr_init, we initialize our own owr_loop_thread
GMainContext *owr_context;
GMainLoop *owr_main_loop;
GThread *owr_thread;

- (void)viewDidLoad
{
    [super viewDidLoad];
    
#ifdef OPUS
    audio_codec_rate = 48000;
    audio_codec_type = OWR_CODEC_TYPE_OPUS;
    audio_codec_channels = 1;
#else
    audio_codec_rate = 8000;
    audio_codec_type = OWR_CODEC_TYPE_PCMA;
    audio_codec_channels = 1;
#endif

    transmit_frame_rate = 30.0;
    render_frame_rate = 60.0;
#if 0
    video_width = 480;
    video_height = 368;
#elif 0
    video_width = 1280;
    video_height = 720;
#elif 1
    video_width = 960;
    video_height = 540;
#elif 0
    video_width = 540;
    video_height = 960;
#endif

    // Setup the AVAudioSession -- otherwise, AudioUnitInitialize would fail
    AVAudioSession *theSession = [AVAudioSession sharedInstance];

#if TEST_CUSTOM_SESSION_RATE
    [theSession setPreferredSampleRate:32000 error:nil];
#else
    [theSession setPreferredSampleRate:audio_codec_rate error:nil];
#endif
    
    [theSession setMode:AVAudioSessionModeVideoChat error:nil];
    [theSession setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];
    [theSession setActive:YES error:nil];
    
    // GStreamer debug settings
    gst_debug_set_threshold_from_string("*:2", TRUE);
    gst_debug_set_color_mode(GST_DEBUG_COLOR_MODE_OFF); // colors and XCode console don't mix
    
    // Tip: It's possible to dump .dot files the the iOS container
    // and then fetch and inspect the container, but it's *much* easier to use:
    //
    // https://gist.github.com/ikonst/6874ff814ab7f2530b2a
    //
    setenv("GST_DEBUG_DUMP_DOT_DIR", [NSTemporaryDirectory() cStringUsingEncoding:NSUTF8StringEncoding], 1);

#ifdef OWR_INIT_WITH_MAIN_CONTEXT
    // Create OWR context
    owr_context = g_main_context_default();
    owr_main_loop  = g_main_loop_new(owr_context, FALSE);
    owr_init_with_main_context(owr_context);
    owr_thread = g_thread_new("owr_main_loop", my_owr_main_loop, (__bridge gpointer)(self));
    NSLog(@"OpenWebRTC initialized");
    
    // all owr calls should occur on the thread owning the owr main context
    g_main_context_invoke(NULL, my_owr_setup, (__bridge gpointer)(self));
#else
    owr_init();
    [self owrSetup];
#endif
}

#ifdef OWR_INIT_WITH_MAIN_CONTEXT
// Trampoline to '- (gpointer)owrMainLoop'
static gpointer my_owr_main_loop(gpointer data) {
    return [((__bridge TestViewController*)data) owrMainLoop];
}

- (gpointer) owrMainLoop {
    g_main_context_push_thread_default(owr_context);
    g_main_loop_run(owr_main_loop);
    g_main_context_pop_thread_default(owr_context);
    return NULL;
}

// Trampoline to '- (void)owrSetup'
gboolean my_owr_setup(gpointer user_data) {
    [((__bridge TestViewController*)user_data) owrSetup];
    return G_SOURCE_REMOVE;
}
#endif

- (void)owrSetup {
    /* PREPARE FOR RENDERING VIDEO */
    
    // Make the video the right size (as opposed to being too big)
    // This is somehow caused by the Retina support, but I didn't yet find out
    // why it doesn't simply Just Work.
    [self.owrView setContentScaleFactor:1.0];
    
    NSLog(@"Registering OWR view %@", self.owrView);
    owr_window_registry_register(owr_window_registry_get(), OWR_VIEW_TAG, (__bridge gpointer)(self.owrView));

    // TODO: In case of orientation changes, according to Apple, we shouldn't use transforms
    //       to change a CAEAGLLayer's orientation; in our case, we shouldn't transform
    //       our GLKView's layer.
    //
    //       We should get GST to do it within the pipeline.
    
#ifdef TEST_LOOPBACK
    /* PREPARE FOR RECEIVING */
    {
        recv_transport_agent = owr_transport_agent_new(FALSE);
        g_assert(OWR_IS_TRANSPORT_AGENT(recv_transport_agent));
        
        owr_transport_agent_set_local_port_range(recv_transport_agent, 5000, 5999);
        owr_transport_agent_add_local_address(recv_transport_agent, "127.0.0.1");
    }
    
    // SEND
    {
        send_transport_agent = owr_transport_agent_new(TRUE);
        g_assert(OWR_IS_TRANSPORT_AGENT(send_transport_agent));
        
        owr_transport_agent_set_local_port_range(send_transport_agent, 5000, 5999);
        owr_transport_agent_add_local_address(send_transport_agent, "127.0.0.1");
    }
    
    recv_session_audio = owr_media_session_new(FALSE);
    if (USE_VIDEO)
        recv_session_video = owr_media_session_new(FALSE);
    send_session_audio = owr_media_session_new(TRUE);
    if (USE_VIDEO)
        send_session_video = owr_media_session_new(TRUE);
    
    g_signal_connect(recv_session_audio, "on-new-candidate", G_CALLBACK(got_candidate), send_session_audio);
    if (USE_VIDEO)
        g_signal_connect(recv_session_video, "on-new-candidate", G_CALLBACK(got_candidate), send_session_video);
    g_signal_connect(send_session_audio, "on-new-candidate", G_CALLBACK(got_candidate), recv_session_audio);
    if (USE_VIDEO)
        g_signal_connect(send_session_video, "on-new-candidate", G_CALLBACK(got_candidate), recv_session_video);
    
#ifdef DISABLE_DTLS
    g_object_set(recv_session_audio, "dtls-certificate", NULL, NULL);
    g_object_set(send_session_audio, "dtls-certificate", NULL, NULL);
#endif
    
    // VIDEO
    if (USE_VIDEO) {
        g_signal_connect(recv_session_video, "on-incoming-source", G_CALLBACK(got_remote_source), NULL);
        
        // 103 is a dynamic payload type (see RTP payload types)
        OwrPayload *receive_payload = owr_video_payload_new(OWR_CODEC_TYPE_H264, 103, 90000, TRUE, FALSE);
        owr_media_session_add_receive_payload(recv_session_video, receive_payload);
        
        owr_transport_agent_add_session(recv_transport_agent, OWR_SESSION(recv_session_video));
    }
    
    // AUDIO
    {
        g_signal_connect(recv_session_audio, "on-incoming-source", G_CALLBACK(got_remote_source), NULL);
        
        OwrPayload *receive_payload = owr_audio_payload_new(audio_codec_type, 100, audio_codec_rate, audio_codec_channels);
        owr_media_session_add_receive_payload(recv_session_audio, receive_payload);
        
        owr_transport_agent_add_session(recv_transport_agent, OWR_SESSION(recv_session_audio));
    }
#endif
    
    /* PREPARE FOR SENDING */
    
    NSLog(@"Getting capture sources...");
    OwrMediaType mediaTypes = OWR_MEDIA_TYPE_AUDIO;
    if (USE_VIDEO)
        mediaTypes |= OWR_MEDIA_TYPE_VIDEO;
    owr_get_capture_sources(mediaTypes, got_sources, NULL);
}

- (void)viewDidAppear:(BOOL)animated
{
    long height = [self.owrView drawableHeight], width = [self.owrView drawableWidth];
    height = height;
    width = width;
}

static void got_remote_source(OwrMediaSession *session, OwrMediaSource *source, gpointer user_data)
{
    gchar *name = NULL;
    OwrMediaRenderer *owr_renderer = NULL;
    OwrMediaType media_type;
    
    g_assert(!user_data);
    
    g_object_get(source, "media-type", &media_type, "name", &name, NULL);
    
    g_print("Got remote source: %s\n", name);
    
    if (media_type == OWR_MEDIA_TYPE_VIDEO) {
        g_print("Creating video renderer\n");
        OwrVideoRenderer *renderer = owr_video_renderer_new(OWR_VIEW_TAG);
        g_assert(renderer);
        
        if (!video_renderer)
            video_renderer = renderer;

        g_print("Connecting source to video renderer\n");
        owr_media_renderer_set_source(OWR_MEDIA_RENDERER(renderer), source);
        owr_renderer = OWR_MEDIA_RENDERER(renderer);
    } else if (media_type == OWR_MEDIA_TYPE_AUDIO) {
        g_print("Creating audio renderer\n");
        OwrAudioRenderer *renderer = owr_audio_renderer_new();
        g_assert(renderer);
        
        if (!audio_renderer)
            audio_renderer = renderer;
        
        g_print("Connecting source to audio renderer\n");
        owr_media_renderer_set_source(OWR_MEDIA_RENDERER(renderer), source);
        owr_renderer = OWR_MEDIA_RENDERER(renderer);
    }
    
    g_free(name);
}

static void got_candidate(OwrMediaSession *session_a, OwrCandidate *candidate, OwrMediaSession *session_b)
{
    owr_session_add_remote_candidate(OWR_SESSION(session_b), candidate);
}

#ifdef HACK
// HACK
struct _OwrMediaRendererPrivate {
    GMutex media_renderer_lock;
    OwrMediaType media_type;
    OwrMediaSource *source;
    gboolean disabled;
    
    GstElement *pipeline;
    GstElement *src, *sink;
};

// HACK
struct _OwrMediaSourcePrivate {
    gchar *name;
    OwrMediaType media_type;
    
    OwrSourceType type;
    OwrCodecType codec_type;
    
    /* The bin or pipeline that contains the data producers */
    GstElement *source_bin;
    /* Tee element from which we can tap the source for multiple consumers */
    GstElement *source_tee;
};
#endif // HACK

static void got_sources(GList *sources, gpointer user_data)
{
    static gboolean have_video = FALSE, have_audio = FALSE;
    
    g_assert(sources);
    
    for (; sources != NULL; sources = sources->next) {
        OwrMediaSource *source = sources->data;
        g_assert(OWR_IS_MEDIA_SOURCE(source));
        
        gchar *source_name;
        OwrMediaType media_type;
        OwrSourceType source_type;
        g_object_get(source, "name", &source_name, "type", &source_type, "media-type", &media_type, NULL);
        gboolean is_back_camera = g_str_equal(source_name, "Back Camera");
        
        if (!have_video && is_back_camera && media_type == OWR_MEDIA_TYPE_VIDEO && source_type == OWR_SOURCE_TYPE_CAPTURE) {
            have_video = TRUE;
            
#ifdef TEST_LOOPBACK
            OwrPayload *payload = owr_video_payload_new(OWR_CODEC_TYPE_H264, 103, 90000, TRUE, FALSE);
            g_object_set(payload, "width", video_width, "height", video_height, "framerate", transmit_frame_rate, NULL);
            owr_media_session_set_send_payload(send_session_video, payload);
            
            owr_media_session_set_send_source(send_session_video, source);
            
            owr_transport_agent_add_session(send_transport_agent, OWR_SESSION(send_session_video));
#endif
            
#ifdef RENDER_SELF_VIEW
            g_print("Displaying self-view\n");
            
            Owrvideo_renderer *renderer = owr_video_renderer_new(NULL);
            g_assert(renderer);
            g_object_set(renderer, "width", video_width, "height", video_height, "max-framerate", transmit_frame_rate, NULL);
            owr_media_renderer_set_source(OWR_MEDIA_RENDERER(renderer), source);
            video_renderer = OWR_MEDIA_RENDERER(renderer);
#endif
            video_source = source;
        } else if (!have_audio && media_type == OWR_MEDIA_TYPE_AUDIO && source_type == OWR_SOURCE_TYPE_CAPTURE) {
            have_audio = TRUE;
            
#ifdef TEST_LOOPBACK
            OwrPayload *payload = owr_audio_payload_new(audio_codec_type, 100, audio_codec_rate, audio_codec_channels);
            owr_media_session_set_send_payload(send_session_audio, payload);
            
            owr_media_session_set_send_source(send_session_audio, source);
            
            owr_transport_agent_add_session(send_transport_agent, OWR_SESSION(send_session_audio));
#endif
            
#ifdef RENDER_SELF_VIEW
            g_print("Playing self-listen\n");
            
            OwrAudioRenderer *renderer = owr_audio_renderer_new();
            g_assert(renderer);

            // HACK: Adjust buffer-time and latency-time
#ifdef HACK
            GstBin *render_bin = (GstBin*)renderer->parent_instance.priv->pipeline;
            GstBin *audio_render_bin0 = (GstBin*)gst_bin_get_by_name(render_bin, "audio-renderer-bin-0");
            GstElement *osxaudio_sink = gst_bin_get_by_name(render_bin, "audio-renderer-sink");
            g_object_set(osxaudio_sink, "buffer-time", 40000,
                         "latency-time", G_GINT64_CONSTANT(10000), NULL);
            GstElement *render_volume = gst_bin_get_by_name(render_bin, "audio-renderer-volume");
            gst_element_unlink(render_volume, osxaudio_sink);
            // add fake sink
            GstElement *fakesink = gst_element_factory_make("fakesink", "my-fakesink");
            g_object_set(fakesink, "async", FALSE, NULL);
            gst_bin_add(audio_render_bin0, fakesink);
            gst_element_link(render_volume, fakesink);
#endif // HACK

            owr_media_renderer_set_source(OWR_MEDIA_RENDERER(renderer), source);

#ifdef HACK
            // HACK
            GstBin *source_bin = (GstBin*)source->priv->source_bin;
            GstElement *sink_bin = gst_bin_get_by_name(source_bin, "source-sink-bin-0");
            gst_element_unlink(source->priv->source_tee, sink_bin); // unlink from actual pipeline
      
#define OUTPUT_QUEUE
#ifdef OUTPUT_QUEUE
            GstElement *osxaudio_sink_queue = gst_element_factory_make("queue", "osxaudio_sink_queue");
            gst_bin_add(source_bin, osxaudio_sink_queue);
#endif
            
            gst_bin_remove(audio_render_bin0, osxaudio_sink);
            gst_bin_add(source_bin, osxaudio_sink);
#ifdef OUTPUT_QUEUE
            gst_element_link(source->priv->source_tee, osxaudio_sink_queue); // hacker's link
            gst_element_link(osxaudio_sink_queue, osxaudio_sink);
            gst_element_set_state(osxaudio_sink_queue, GST_STATE_PLAYING);
#else
            gst_element_link(source->priv->source_tee, osxaudio_sink);
#endif
            gst_element_set_state(osxaudio_sink, GST_STATE_PLAYING);
#endif // HACK
            
            audio_renderer = OWR_MEDIA_RENDERER(renderer);
#endif
            audio_source = source;
        }
        
        g_free(source_name);
        
        if ((!USE_VIDEO || have_video) && have_audio)
            break;
    }
}

@end

