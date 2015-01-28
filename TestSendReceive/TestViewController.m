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

#define OWR_VIEW_TAG "owr-view"

@interface TestViewController ()

@property (weak) IBOutlet GLKView *owrView;

@end

@implementation TestViewController

OwrVideoRenderer *videoRenderer = NULL;
OwrAudioRenderer *audioRenderer = NULL;
OwrMediaSession *recv_session_audio = NULL, *recv_session_video = NULL, *send_session_audio = NULL, *send_session_video = NULL;
OwrTransportAgent *send_transport_agent, *recv_transport_agent;

// Whether to render the local view (before sending)
#undef RENDER_SELF_VIEW

// Disabling this flag keeps only audio support
bool use_video = false;

int video_width, video_height;
float transmit_frame_rate, render_frame_rate;
guint audio_sample_rate;
guint audio_channels;
OwrCodecType audio_codec_type;

#define OPUS
const int PCMA_SAMPLE_RATE = 8000;
const int OPUS_SAMPLE_RATE = 48000;

// Instead of using owr_init, we initialize our own owr_loop_thread
GMainContext *owr_context;
GMainLoop *owr_main_loop;
GThread *owr_thread;

- (void)viewDidLoad
{
    [super viewDidLoad];
    
#ifdef OPUS
    audio_sample_rate = OPUS_SAMPLE_RATE;
    audio_codec_type = OWR_CODEC_TYPE_OPUS;
    audio_channels = 1;
#else
    audio_sample_rate = PCMA_SAMPLE_RATE;
    audio_codec_type = OWR_CODEC_TYPE_PCMA;
    audio_channels = 1;
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
    AVAudioSession *mySession = [AVAudioSession sharedInstance];
    NSError *audioSessionError = nil;

#if 0
    [mySession setPreferredSampleRate:audio_sample_rate  error:&audioSessionError];
    unsigned int hardcoded_frames = 4196; // from osxaudio gst source code
    NSTimeInterval bufferDuration = (double)hardcoded_frames / (double)audio_sample_rate;
    [mySession setPreferredIOBufferDuration:bufferDuration error:&audioSessionError];
    [mySession setPreferredInputNumberOfChannels:audio_channels error:&audioSessionError];
    [mySession setPreferredOutputNumberOfChannels:audio_channels error:&audioSessionError];
#endif
    [mySession setCategory: AVAudioSessionCategoryPlayAndRecord error:&audioSessionError];

    [mySession setActive:YES error:&audioSessionError];
    
    // Confirm our settings now, once the AVAudioSession is active
#if 0
    double preferred_audio_sample_rate = [mySession sampleRate];
    assert(audio_sample_rate == preferred_audio_sample_rate);
    // We have to accept what the system gives us still
    audio_sample_rate = preferred_audio_sample_rate;
#endif
    setenv("GST_DEBUG_DUMP_DOT_DIR", [NSTemporaryDirectory() cStringUsingEncoding:NSUTF8StringEncoding], 1);
    setenv("GST_DEBUG", "0", 1);
    setenv("GST_DEBUG_NO_COLOR", "1", 1); // colors don't display on XCode console
    
    owr_context = g_main_context_default();
    owr_main_loop  = g_main_loop_new(owr_context, FALSE);
    owr_init_with_main_context(owr_context);
    owr_thread = g_thread_new("owr_main_loop", my_owr_main_loop, (__bridge gpointer)(self));
    NSLog(@"OpenWebRTC initialized");
    
    // all owr calls should occur on the thread owning the owr main context
    g_main_context_invoke(NULL, my_owr_setup, (__bridge gpointer)(self));
}

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
    if (use_video)
        recv_session_video = owr_media_session_new(FALSE);
    send_session_audio = owr_media_session_new(TRUE);
    if (use_video)
        send_session_video = owr_media_session_new(TRUE);
    
    g_signal_connect(recv_session_audio, "on-new-candidate", G_CALLBACK(got_candidate), send_session_audio);
    if (use_video)
        g_signal_connect(recv_session_video, "on-new-candidate", G_CALLBACK(got_candidate), send_session_video);
    g_signal_connect(send_session_audio, "on-new-candidate", G_CALLBACK(got_candidate), recv_session_audio);
    if (use_video)
        g_signal_connect(send_session_video, "on-new-candidate", G_CALLBACK(got_candidate), recv_session_video);
    
    // VIDEO
    if (use_video) {
        g_signal_connect(recv_session_video, "on-incoming-source", G_CALLBACK(got_remote_source), NULL);
        
        // 103 is a dynamic payload type (see RTP payload types)
        OwrPayload *receive_payload = owr_video_payload_new(OWR_CODEC_TYPE_H264, 103, 90000, TRUE, FALSE);
        owr_media_session_add_receive_payload(recv_session_video, receive_payload);
        
        owr_transport_agent_add_session(recv_transport_agent, OWR_SESSION(recv_session_video));
    }
    
    // AUDIO
    {
        g_signal_connect(recv_session_audio, "on-incoming-source", G_CALLBACK(got_remote_source), NULL);
        
        OwrPayload *receive_payload = owr_audio_payload_new(audio_codec_type, 100, audio_sample_rate, audio_channels);
        owr_media_session_add_receive_payload(recv_session_audio, receive_payload);
        
        owr_transport_agent_add_session(recv_transport_agent, OWR_SESSION(recv_session_audio));
    }
    
    /* PREPARE FOR SENDING */
    
    NSLog(@"Getting capture sources...");
    OwrMediaType mediaTypes = OWR_MEDIA_TYPE_AUDIO;
    if (use_video)
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
        OwrVideoRenderer *renderer;
        
        g_print("Creating video renderer\n");
        renderer = owr_video_renderer_new(OWR_VIEW_TAG);
        g_assert(renderer);
        
        g_print("Connecting source to video renderer\n");
        owr_media_renderer_set_source(OWR_MEDIA_RENDERER(renderer), source);
        owr_renderer = OWR_MEDIA_RENDERER(renderer);
    } else if (media_type == OWR_MEDIA_TYPE_AUDIO) {
        OwrAudioRenderer *renderer;
        
        g_print("Creating audio renderer\n");
        renderer = owr_audio_renderer_new();
        g_assert(renderer);
        
        g_print("Connecting source to audio renderer\n");
        owr_media_renderer_set_source(OWR_MEDIA_RENDERER(renderer), source);
        owr_renderer = OWR_MEDIA_RENDERER(renderer);
    }
    
    g_free(name);

    if (media_type == OWR_MEDIA_TYPE_VIDEO) {
        write_dot_file("test_receive-got_remote_source-video-source", owr_media_source_get_dot_data(source), TRUE);
        write_dot_file("test_receive-got_remote_source-video-renderer", owr_media_renderer_get_dot_data(owr_renderer), TRUE);
    } else {
        write_dot_file("test_receive-got_remote_source-audio-source", owr_media_source_get_dot_data(source), TRUE);
        write_dot_file("test_receive-got_remote_source-audio-renderer", owr_media_renderer_get_dot_data(owr_renderer), TRUE);
    }
}

static void got_candidate(OwrMediaSession *session_a, OwrCandidate *candidate, OwrMediaSession *session_b)
{
    owr_session_add_remote_candidate(OWR_SESSION(session_b), candidate);
}

static void got_sources(GList *sources, gpointer user_data)
{
    static gboolean have_video = FALSE, have_audio = FALSE;
#ifdef RENDER_SELF_VIEW
    OwrMediaRenderer *video_renderer = NULL;
#endif
    OwrMediaSource *audio_source = NULL, *video_source = NULL;
    
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
            
            
            OwrPayload *payload = owr_video_payload_new(OWR_CODEC_TYPE_H264, 103, 90000, TRUE, FALSE);
            g_object_set(payload, "width", video_width, "height", video_height, "framerate", transmit_frame_rate, NULL);
            owr_media_session_set_send_payload(send_session_video, payload);
            
            owr_media_session_set_send_source(send_session_video, source);
            
            owr_transport_agent_add_session(send_transport_agent, OWR_SESSION(send_session_video));
            
#ifdef RENDER_SELF_VIEW
            g_print("Displaying self-view\n");
            
            OwrVideoRenderer *renderer = owr_video_renderer_new(NULL);
            g_assert(renderer);
            g_object_set(renderer, "width", video_width, "height", video_height, "max-framerate", transmit_frame_rate, NULL);
            owr_media_renderer_set_source(OWR_MEDIA_RENDERER(renderer), source);
            video_renderer = OWR_MEDIA_RENDERER(renderer);
#endif
            video_source = source;
        } else if (!have_audio && media_type == OWR_MEDIA_TYPE_AUDIO && source_type == OWR_SOURCE_TYPE_CAPTURE) {
            have_audio = TRUE;
            
            OwrPayload *payload = owr_audio_payload_new(audio_codec_type, 100, audio_sample_rate, audio_channels);
            owr_media_session_set_send_payload(send_session_audio, payload);
            
            owr_media_session_set_send_source(send_session_audio, source);
            
            owr_transport_agent_add_session(send_transport_agent, OWR_SESSION(send_session_audio));
            
            audio_source = source;
        }
        
        g_free(source_name);
        
        if ((!use_video || have_video) && have_audio)
            break;
    }

    if (audio_source)
        write_dot_file("test_send-got_source-audio-source", owr_media_source_get_dot_data(audio_source), TRUE);
    if (video_source)
        write_dot_file("test_send-got_source-video-source", owr_media_source_get_dot_data(video_source), TRUE);
#ifdef RENDER_SELF_VIEW
    if (video_renderer)
        write_dot_file("test_send-got_source-video-renderer", owr_media_renderer_get_dot_data(video_renderer), TRUE);
#endif
}

void write_dot_file(const gchar *base_file_name, gchar *dot_data, gboolean with_timestamp)
{
    g_return_if_fail(base_file_name);
    g_return_if_fail(dot_data);
    
    gchar *timestamp = NULL;
    if (with_timestamp) {
        GTimeVal time;
        g_get_current_time(&time);
        timestamp = g_time_val_to_iso8601(&time);
    }
    
    const char *path = [NSTemporaryDirectory() cStringUsingEncoding:NSUTF8StringEncoding];
    gchar *filename = g_strdup_printf("%s/%s%s%s.dot", path[0] ? path : ".",
                               timestamp ? timestamp : "", timestamp ? "-" : "", base_file_name);
    gboolean success = g_file_set_contents(filename, dot_data, -1, NULL);
    g_warn_if_fail(success);
    
    g_free(dot_data);
    g_free(filename);
    g_free(timestamp);
}
@end
