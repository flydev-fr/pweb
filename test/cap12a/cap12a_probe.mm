/*
 * CAP-12A: the macOS / WKWebView blob data-plane probe.
 *
 * ############################################################
 * ##  NOT COMPILED AND NOT RUN ANYWHERE AS OF THIS COMMIT.  ##
 * ############################################################
 *
 * The CAP-12A shard was run on a Windows host with WSL, which can reach
 * WebView2 and WebKitGTK and cannot reach WKWebView. Every macOS row in
 * `cap12a-decision-artifact.md` is therefore DERIVED - from Apple's
 * documented WKURLSchemeHandler contract and from what CAP-7M already
 * MEASURED in `docs/wkwebview-macos-semantics.md` - and is marked as such.
 * This file is the instrument that turns those rows into measurements, and
 * it has never been through a compiler. Treat its first run as a debugging
 * session, not as a measurement.
 *
 * WHY IT IS AN OBJECTIVE-C++ PROBE AND NOT THE PASCAL HOST. The Windows and
 * Linux legs run `blobprobe.pas` because their engine surfaces are plain C
 * or COM and a Pascal handler can reach them. WKURLSchemeHandler is an
 * Objective-C protocol whose implementation has to be a class; the product
 * reaches it through `src/platform/macos/pweb_cocoa_bridge.mm`, and a
 * measuring instrument for a protocol that production cannot yet satisfy
 * belongs in the same language. This follows `test/cap7m/cap7m_probe.mm`,
 * which is the repository's precedent for exactly this shape.
 *
 * IT WRITES THE SAME JSON AS blobprobe.pas, deliberately: `summarize.js` is
 * the one place a row becomes a verdict, and a second interpreter for one
 * engine is how three engines end up with three different meanings of the
 * word "streaming".
 *
 * Conventions borrowed from test/cap7m/cap7m_probe.mm: MARKER key=value on
 * stdout, CAP12A_FAIL reason=... on stderr, exit 0 pass / 1 fail / 2 usage,
 * watchdog-bounded, and the page reports its OWN facts rather than having
 * them inferred from "it rendered".
 *
 * Build and run: test/cap12a/run_cap12a_macos.sh
 */

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>

// ------------------------------------------------------------------ clock

static uint64_t g_clock_base = 0;

static uint64_t now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  uint64_t v = (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)(ts.tv_nsec / 1000);
  return v - g_clock_base;
}

// ----------------------------------------------------------- the timeline

struct TimelineEntry {
  uint64_t us;
  int64_t value;
  std::string event;
  std::string detail;
};

static std::vector<TimelineEntry> g_timeline;
static NSLock *g_timeline_lock = nil;
static const size_t TIMELINE_MAX = 20000;
static std::atomic<int> g_timeline_dropped(0);

static void mark(const char *event, const char *detail, int64_t value) {
  // the timestamp is taken BEFORE the lock, so a contended timeline cannot
  // reorder two events that really happened in that order
  uint64_t us = now_us();
  [g_timeline_lock lock];
  if (g_timeline.size() >= TIMELINE_MAX) {
    g_timeline_dropped++;
  } else {
    TimelineEntry e;
    e.us = us;
    e.value = value;
    e.event = event ? event : "";
    e.detail = detail ? detail : "";
    g_timeline.push_back(e);
  }
  [g_timeline_lock unlock];
}

static std::string json_quote(const std::string &s) {
  static const char *HEX = "0123456789abcdef";
  std::string out = "\"";
  for (size_t i = 0; i < s.size(); i++) {
    unsigned char c = (unsigned char)s[i];
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\t': out += "\\t"; break;
      case '\n': out += "\\n"; break;
      case '\f': out += "\\f"; break;
      case '\r': out += "\\r"; break;
      default:
        if (c < 0x20) {
          out += "\\u00";
          out += HEX[c >> 4];
          out += HEX[c & 15];
        } else {
          out += (char)c;
        }
    }
  }
  out += "\"";
  return out;
}

static std::string timeline_json(void) {
  std::string out = "[";
  [g_timeline_lock lock];
  for (size_t i = 0; i < g_timeline.size(); i++) {
    if (i) { out += ","; }
    char head[64];
    snprintf(head, sizeof(head), "{\"us\":%llu,\"e\":",
             (unsigned long long)g_timeline[i].us);
    out += head;
    out += json_quote(g_timeline[i].event);
    if (!g_timeline[i].detail.empty()) {
      out += ",\"d\":";
      out += json_quote(g_timeline[i].detail);
    }
    if (g_timeline[i].value) {
      char v[48];
      snprintf(v, sizeof(v), ",\"v\":%lld", (long long)g_timeline[i].value);
      out += v;
    }
    out += "}";
  }
  [g_timeline_lock unlock];
  out += "]";
  return out;
}

// ------------------------------------------------------------------- RSS

// task_basic_info's resident_size is the Darwin counterpart of
// /proc/self/statm's resident field: the CURRENT figure, not a lifetime high
// water mark, so the sampler below can turn it into a per-row maximum.
#include <mach/mach.h>

static int64_t process_rss_bytes(void) {
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                (task_info_t)&info, &count) != KERN_SUCCESS) {
    return -1;
  }
  return (int64_t)info.resident_size;
}

static std::atomic<long long> g_rss_max(0);
static std::atomic<int> g_rss_samples(0);
static std::atomic<bool> g_rss_run(false);

static int64_t rss_mark_baseline(void) {
  int64_t v = process_rss_bytes();
  if (v < 0) { v = 0; }
  g_rss_max = v;
  return v;
}

// -------------------------------------------------------- the blob plans

enum PlanKind { PK_NONE, PK_WHOLE, PK_STREAM, PK_SSE, PK_WAV, PK_PNG, PK_ECHO };

struct BlobPlan {
  PlanKind kind;
  int64_t total;     // -1 when the plan deliberately declares no length
  int chunks;
  int chunk_bytes;
  int delay_ms;
  bool ranged;
  std::string content_type;
  std::string id;
};

static const int PATTERN_MOD = 251;
static const int WAV_RATE = 8000;
static const int WAV_HEADER = 44;
static const char *BLOB_PREFIX = "_pweb/blob/";

// The SAME grammar blobsource.pas implements, and the fact that it is a
// second implementation is why every field is re-derived from the id rather
// than defaulted: a row whose plan differs between engines is a row that
// compares two different measurements.
static bool parse_plan(const std::string &id, BlobPlan &plan) {
  plan = BlobPlan();
  plan.kind = PK_NONE;
  plan.total = 0;
  plan.chunks = 0;
  plan.chunk_bytes = 0;
  plan.delay_ms = 0;
  plan.ranged = false;
  plan.content_type = "application/octet-stream";
  plan.id = id;

  std::vector<std::string> f;
  size_t start = 0;
  while (start <= id.size()) {
    size_t dash = id.find('-', start);
    if (dash == std::string::npos) {
      f.push_back(id.substr(start));
      break;
    }
    f.push_back(id.substr(start, dash - start));
    start = dash + 1;
  }
  if (f.empty() || f[0].empty()) { return false; }
  auto num = [&](size_t i, long long lo, long long hi, long long &out) -> bool {
    if (i >= f.size() || f[i].empty() || f[i].size() > 18) { return false; }
    long long v = 0;
    for (size_t k = 0; k < f[i].size(); k++) {
      if (f[i][k] < '0' || f[i][k] > '9') { return false; }
      v = v * 10 + (f[i][k] - '0');
    }
    out = v;
    return v >= lo && v <= hi;
  };

  const std::string &verb = f[0];
  long long a = 0, b = 0, c = 0;
  if (verb == "whole" || verb == "ranged") {
    if (f.size() != 2 || !num(1, 0, 512LL * 1024 * 1024, a)) { return false; }
    plan.kind = PK_WHOLE;
    plan.total = a;
    plan.chunks = 1;
    plan.chunk_bytes = (int)a;
    plan.ranged = (verb == "ranged");
  } else if (verb == "stream" || verb == "streamnolen") {
    if (f.size() != 4 || !num(1, 1, 4096, a) || !num(2, 1, 64 * 1024 * 1024, b) ||
        !num(3, 0, 60000, c)) {
      return false;
    }
    plan.kind = PK_STREAM;
    plan.chunks = (int)a;
    plan.chunk_bytes = (int)b;
    plan.delay_ms = (int)c;
    plan.total = (verb == "stream") ? a * b : -1;
  } else if (verb == "sse") {
    if (f.size() != 3 || !num(1, 1, 1000, a) || !num(2, 0, 60000, b)) {
      return false;
    }
    plan.kind = PK_SSE;
    plan.chunks = (int)a;
    plan.delay_ms = (int)b;
    plan.total = -1;
    plan.content_type = "text/event-stream";
  } else if (verb == "wav" || verb == "wavnorange" || verb == "wavx") {
    if (f.size() != 2 || !num(1, 1, 600, a)) { return false; }
    plan.kind = PK_WAV;
    plan.total = WAV_HEADER + a * WAV_RATE;
    plan.chunks = 1;
    plan.chunk_bytes = (int)plan.total;
    plan.content_type = (verb == "wavx") ? "audio/x-wav" : "audio/wav";
    plan.ranged = (verb != "wavnorange");
  } else if (verb == "png") {
    if (f.size() != 1) { return false; }
    plan.kind = PK_PNG;
    plan.content_type = "image/png";
    plan.ranged = true;
  } else if (verb == "echo") {
    if (f.size() != 1) { return false; }
    plan.kind = PK_ECHO;
    plan.content_type = "application/json";
  } else {
    return false;
  }
  return true;
}

// the same 1x1 PNG blobsource.pas carries, as raw bytes
static const unsigned char TINY_PNG[] = {
  0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x00,0x00,0x00,0x0D,0x49,0x48,0x44,
  0x52,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,0x08,0x06,0x00,0x00,0x00,0x1F,
  0x15,0xC4,0x89,0x00,0x00,0x00,0x0D,0x49,0x44,0x41,0x54,0x78,0xDA,0x63,0xFC,
  0xCF,0xC0,0x50,0x0F,0x00,0x04,0x85,0x01,0x80,0x84,0xA9,0x8C,0x21,0x00,0x00,
  0x00,0x00,0x49,0x45,0x4E,0x44,0xAE,0x42,0x60,0x82
};

static void put_le32(unsigned char *d, uint32_t v) {
  d[0] = (unsigned char)(v & 0xFF);
  d[1] = (unsigned char)((v >> 8) & 0xFF);
  d[2] = (unsigned char)((v >> 16) & 0xFF);
  d[3] = (unsigned char)((v >> 24) & 0xFF);
}

static void put_le16(unsigned char *d, uint16_t v) {
  d[0] = (unsigned char)(v & 0xFF);
  d[1] = (unsigned char)((v >> 8) & 0xFF);
}

static void fill_plan_range(const BlobPlan &plan, unsigned char *dst,
                            int64_t offset, int64_t count) {
  if (!dst || count <= 0) { return; }
  if (plan.kind == PK_PNG) {
    if (offset + count > (int64_t)sizeof(TINY_PNG)) { return; }
    memcpy(dst, TINY_PNG + offset, (size_t)count);
    return;
  }
  int64_t head = 0;
  if (plan.kind == PK_WAV && offset < WAV_HEADER) {
    unsigned char h[WAV_HEADER];
    memset(h, 0, sizeof(h));
    uint32_t data = (uint32_t)(plan.total - WAV_HEADER);
    memcpy(h, "RIFF", 4);
    put_le32(h + 4, 36 + data);
    memcpy(h + 8, "WAVE", 4);
    memcpy(h + 12, "fmt ", 4);
    put_le32(h + 16, 16);
    put_le16(h + 20, 1);
    put_le16(h + 22, 1);
    put_le32(h + 24, WAV_RATE);
    put_le32(h + 28, WAV_RATE);
    put_le16(h + 32, 1);
    put_le16(h + 34, 8);
    memcpy(h + 36, "data", 4);
    put_le32(h + 40, data);
    head = WAV_HEADER - offset;
    if (head > count) { head = count; }
    memcpy(dst, h + offset, (size_t)head);
  }
  int64_t base = offset + head - (plan.kind == PK_WAV ? WAV_HEADER : 0);
  int v = (int)(((base % PATTERN_MOD) + PATTERN_MOD) % PATTERN_MOD);
  for (int64_t i = head; i < count; i++) {
    dst[i] = (unsigned char)v;
    if (++v == PATTERN_MOD) { v = 0; }
  }
}

// `bytes=a-b`, `bytes=a-` and `bytes=-suffix`; multi-range is REFUSED rather
// than partially honoured, because answering the first window of a
// multi-range request with a plain 206 lies to the engine about what was sent
static bool parse_single_range(const std::string &raw, int64_t total,
                               int64_t &first, int64_t &last) {
  first = 0;
  last = -1;
  if (total <= 0 || raw.size() > 128) { return false; }
  std::string s;
  for (size_t i = 0; i < raw.size(); i++) {
    if (raw[i] != ' ') { s += raw[i]; }
  }
  if (s.compare(0, 6, "bytes=") != 0) { return false; }
  s = s.substr(6);
  if (s.find(',') != std::string::npos) { return false; }
  size_t dash = s.find('-');
  if (dash == std::string::npos) { return false; }
  std::string lhs = s.substr(0, dash);
  std::string rhs = s.substr(dash + 1);
  auto num = [](const std::string &t, int64_t &out) -> bool {
    if (t.empty() || t.size() > 18) { return false; }
    int64_t v = 0;
    for (size_t i = 0; i < t.size(); i++) {
      if (t[i] < '0' || t[i] > '9') { return false; }
      v = v * 10 + (t[i] - '0');
    }
    out = v;
    return true;
  };
  int64_t a = 0, b = 0;
  if (lhs.empty()) {
    if (!num(rhs, b) || b < 1 || b > total) { return false; }
    first = total - b;
    last = total - 1;
    return true;
  }
  if (!num(lhs, a) || a > total - 1) { return false; }
  if (rhs.empty()) {
    b = total - 1;
  } else if (!num(rhs, b)) {
    return false;
  }
  if (b > total - 1) { b = total - 1; }
  if (b < a) { return false; }
  first = a;
  last = b;
  return true;
}

// ------------------------------------------------------- global probe state

static NSString *g_csp = nil;         // read from build/cap12a/csp.txt
static NSString *g_fixture_dir = nil;
static NSString *g_out_path = nil;
static NSString *g_report_json = nil;
static std::atomic<int> g_marks(0);
static std::atomic<int> g_seq(0);
static std::atomic<int> g_second_authority(0);
static std::atomic<int> g_requests_with_headers(0);
static std::atomic<int> g_requests_with_body(0);
static std::atomic<int> g_body_as_stream(0);
static std::atomic<int> g_body_as_data(0);
static std::atomic<int> g_handler_off_main(0);
static std::string g_methods_seen;
static std::string g_rss_phases;
static std::string g_rss_phase_sep;
static std::string g_current_phase;
static int64_t g_current_phase_base = 0;

static void phase_begin(const std::string &name) {
  g_current_phase = name;
  g_current_phase_base = rss_mark_baseline();
}

static void phase_end(void) {
  if (g_current_phase.empty()) { return; }
  long long peak = g_rss_max.load();
  char buf[320];
  snprintf(buf, sizeof(buf),
           "%s{\"phase\":\"%s\",\"baseline_bytes\":%lld,\"peak_bytes\":%lld,"
           "\"delta_bytes\":%lld}",
           g_rss_phase_sep.c_str(), g_current_phase.c_str(),
           (long long)g_current_phase_base, peak,
           peak - (long long)g_current_phase_base);
  g_rss_phases += buf;
  g_rss_phase_sep = ",";
  g_current_phase.clear();
}

// --------------------------------------------------- the claim-once guard

// CAP-7M constraint 1, and this probe is the first thing in the repository
// that NEEDS it rather than merely holding it: a chunked body delivers
// didReceiveData: from a dispatch_after long after startURLSchemeTask: has
// returned, so stopURLSchemeTask: really can interleave and a post-stop
// callback really would raise an NSException.
enum TaskState { TS_NEW = 0, TS_SERVING = 1, TS_DONE = 2 };

@interface TaskBox : NSObject
@property(nonatomic, assign) id<WKURLSchemeTask> task;
@property(nonatomic, assign) int state;
@property(nonatomic, assign) int generation;
@end

@implementation TaskBox
@end

static NSMutableArray<TaskBox *> *g_tasks = nil;
static NSLock *g_tasks_lock = nil;
static std::atomic<int> g_stops(0);
static std::atomic<int> g_stops_while_serving(0);
static std::atomic<int> g_suppressed(0);
static std::atomic<int> g_exceptions(0);

static TaskBox *track_task(id<WKURLSchemeTask> task) {
  TaskBox *box = [[TaskBox alloc] init];
  box.task = task;
  box.state = TS_NEW;
  [g_tasks_lock lock];
  [g_tasks addObject:box];
  [g_tasks_lock unlock];
  return box;
}

// claim and REMOVE are separate steps: a task stays tracked until its
// terminal callback has actually been delivered, so an exception out of
// didReceiveResponse: cannot leave a task that is untracked and unterminated
static bool claim(TaskBox *box) {
  bool ok = false;
  [g_tasks_lock lock];
  if (box.state != TS_DONE) {
    box.state = TS_DONE;
    ok = true;
  }
  [g_tasks_lock unlock];
  if (!ok) { g_suppressed++; }
  return ok;
}

static bool mark_serving(TaskBox *box) {
  bool ok = false;
  [g_tasks_lock lock];
  if (box.state == TS_NEW) {
    box.state = TS_SERVING;
    ok = true;
  }
  [g_tasks_lock unlock];
  return ok;
}

static void settle(TaskBox *box) {
  [g_tasks_lock lock];
  [g_tasks removeObject:box];
  [g_tasks_lock unlock];
}

static bool is_live(TaskBox *box) {
  bool live = false;
  [g_tasks_lock lock];
  live = [g_tasks containsObject:box] && box.state != TS_DONE;
  [g_tasks_lock unlock];
  return live;
}

// ---------------------------------------------------------- the handler

@interface Cap12aSchemeHandler : NSObject <WKURLSchemeHandler>
@end

static NSDictionary *build_headers(NSString *contentType, int64_t bodyLen,
                                   bool partial, bool ranged,
                                   int64_t first, int64_t last, int64_t total) {
  NSMutableDictionary *h = [NSMutableDictionary dictionaryWithCapacity:12];
  // THE POLICY BLOCK FIRST, the two body facts last, exactly as the
  // production bridge orders them: a header line that could displace
  // Content-Type would be a sniffing hole reachable by editing one string.
  if (g_csp != nil) { [h setObject:g_csp forKey:@"Content-Security-Policy"]; }
  [h setObject:@"nosniff" forKey:@"X-Content-Type-Options"];
  [h setObject:@"no-referrer" forKey:@"Referrer-Policy"];
  [h setObject:@"no-store" forKey:@"Cache-Control"];
  if (ranged) { [h setObject:@"bytes" forKey:@"Accept-Ranges"]; }
  if (partial) {
    [h setObject:[NSString stringWithFormat:@"bytes %lld-%lld/%lld",
                                            (long long)first, (long long)last,
                                            (long long)total]
          forKey:@"Content-Range"];
  }
  [h setObject:contentType forKey:@"Content-Type"];
  // Content-Length is OMITTED for a body that stays open: CAP-7M0 measured
  // that a declared length a response never delivers makes fetch() reject on
  // a truncated body
  if (bodyLen >= 0) {
    [h setObject:[NSString stringWithFormat:@"%lld", (long long)bodyLen]
          forKey:@"Content-Length"];
  }
  return h;
}

static void deliver_chunk(TaskBox *box, const BlobPlan plan, int index,
                          const std::string tag);

static void schedule_chunk(TaskBox *box, const BlobPlan plan, int index,
                           const std::string tag) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)plan.delay_ms * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
    deliver_chunk(box, plan, index, tag);
  });
}

static std::string sse_frame(int index, uint64_t us) {
  char buf[192];
  snprintf(buf, sizeof(buf),
           "id: %d\nevent: tick\ndata: {\"i\":%d,\"produced_us\":%llu}\n\n",
           index, index, (unsigned long long)us);
  return std::string(buf);
}

static void deliver_chunk(TaskBox *box, const BlobPlan plan, int index,
                          const std::string tag) {
  // the owning cycle captured this block by value; if the task has already
  // been stopped or settled there is nothing to deliver and nothing to raise
  if (!is_live(box)) {
    mark((tag + ".abandoned").c_str(), "", index);
    return;
  }
  NSData *data = nil;
  if (plan.kind == PK_SSE) {
    std::string f = sse_frame(index, now_us());
    data = [NSData dataWithBytes:f.data() length:f.size()];
  } else {
    NSMutableData *m = [NSMutableData dataWithLength:(NSUInteger)plan.chunk_bytes];
    fill_plan_range(plan, (unsigned char *)[m mutableBytes],
                    (int64_t)index * plan.chunk_bytes, plan.chunk_bytes);
    data = m;
  }
  // PRODUCE IS MARKED BEFORE THE DELIVERY, and that ordering is the whole M1
  // verdict: "the page saw chunk 0 before chunk N-1 was produced" has to
  // compare against the earliest instant this process could have had it.
  mark((tag + ".produce").c_str(), "", index);
  @try {
    [box.task didReceiveData:data];
  } @catch (NSException *e) {
    (void)e;
    g_exceptions++;
    mark((tag + ".deliver_raised").c_str(), "", index);
    return;
  }
  if (index + 1 < plan.chunks) {
    schedule_chunk(box, plan, index + 1, tag);
    return;
  }
  if (claim(box)) {
    @try {
      [box.task didFinish];
    } @catch (NSException *e) {
      (void)e;
      g_exceptions++;
    }
  }
  mark((tag + ".eof").c_str(), "", index);
  settle(box);
}

@implementation Cap12aSchemeHandler

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
  int seq = ++g_seq;
  if (![NSThread isMainThread]) { g_handler_off_main++; }
  NSURLRequest *req = [task request];
  NSString *uri = [[req URL] absoluteString];
  mark("req.enter", [uri UTF8String], seq);

  TaskBox *box = track_task(task);
  mark_serving(box);

  NSString *method = [req HTTPMethod];
  if (method == nil) { method = @"GET"; }
  mark("req.got_method", [method UTF8String], seq);
  if (g_methods_seen.find(std::string([method UTF8String]) + ",") ==
      std::string::npos) {
    g_methods_seen += std::string([method UTF8String]) + ",";
  }

  NSDictionary *headers = [req allHTTPHeaderFields];
  if (headers != nil) { g_requests_with_headers++; }
  NSString *range = headers ? [headers objectForKey:@"Range"] : nil;
  mark("req.read_range", range ? [range UTF8String] : "", seq);

  // M3, AND THE WHOLE QUESTION APPLE'S DOCUMENTATION DOES NOT ANSWER:
  // NSURLRequest carries EITHER an HTTPBody or an HTTPBodyStream, and which
  // one WebKit populates for a Blob-backed fetch body is exactly what this
  // row measures. Both are read; the report says which one was there.
  NSData *body = [req HTTPBody];
  NSInputStream *bodyStream = [req HTTPBodyStream];
  if (body != nil) { g_body_as_data++; }
  if (bodyStream != nil) { g_body_as_stream++; }
  if (body != nil || bodyStream != nil) { g_requests_with_body++; }
  mark("req.got_body",
       body != nil ? "HTTPBody" : (bodyStream != nil ? "HTTPBodyStream" : ""),
       seq);

  mark("req.open", [uri UTF8String], seq);
  if (range != nil) { mark("req.range", [range UTF8String], seq); }

  // THE AUTHORITY CHECK IS AN EXACT STRING TEST, not a parser: this probe
  // must never become a second URI validator. PWebParseAppUri is the only
  // thing in this repository that renders that verdict.
  NSString *host = [[req URL] host];
  if (host == nil || ![host isEqualToString:@"app"]) {
    g_second_authority++;
    mark("req.refused", [uri UTF8String], seq);
    if (claim(box)) {
      @try {
        [task didFailWithError:[NSError errorWithDomain:@"cap12a" code:1
                                               userInfo:nil]];
      } @catch (NSException *e) { (void)e; g_exceptions++; }
    }
    settle(box);
    return;
  }

  NSString *path = [[req URL] path];
  std::string logical = path ? [path UTF8String] : "";
  if (!logical.empty() && logical[0] == '/') { logical = logical.substr(1); }
  if (logical.empty()) { logical = "index.html"; }

  std::string tag = "blob" + std::to_string(seq);
  BlobPlan plan;
  bool isBlob = logical.compare(0, strlen(BLOB_PREFIX), BLOB_PREFIX) == 0 &&
                parse_plan(logical.substr(strlen(BLOB_PREFIX)), plan);

  if (isBlob && plan.kind == PK_ECHO) {
    int64_t received = 0;
    int chunks = 0;
    bool patternOk = true;
    int firstByte = -1;
    if (body != nil) {
      received = (int64_t)[body length];
      chunks = 1;
      const unsigned char *p = (const unsigned char *)[body bytes];
      if (received > 0) { firstByte = p[0]; }
      for (int64_t i = 0; i < received; i++) {
        if (p[i] != (unsigned char)(i % PATTERN_MOD)) { patternOk = false; break; }
      }
    } else if (bodyStream != nil) {
      [bodyStream open];
      unsigned char buf[262144];
      NSInteger n;
      while ((n = [bodyStream read:buf maxLength:sizeof(buf)]) > 0) {
        chunks++;
        if (received == 0) { firstByte = buf[0]; }
        for (NSInteger i = 0; i < n; i++) {
          if (buf[i] != (unsigned char)((received + i) % PATTERN_MOD)) {
            patternOk = false;
            break;
          }
        }
        received += n;
        mark("m3.read", "", received);
      }
      [bodyStream close];
    }
    char json[320];
    snprintf(json, sizeof(json),
             "{\"received\":%lld,\"chunks\":%d,\"first_byte\":%d,"
             "\"pattern_ok\":%s,\"read_us\":0}",
             (long long)received, chunks, firstByte,
             patternOk ? "true" : "false");
    NSData *out = [NSData dataWithBytes:json length:strlen(json)];
    mark("m3.finished", "", received);
    if (claim(box)) {
      @try {
        NSHTTPURLResponse *r =
            [[NSHTTPURLResponse alloc] initWithURL:[req URL]
                                        statusCode:200
                                       HTTPVersion:@"HTTP/1.1"
                                      headerFields:build_headers(
                                          @"application/json",
                                          (int64_t)[out length], false, false,
                                          0, 0, 0)];
        [task didReceiveResponse:r];
        [task didReceiveData:out];
        [task didFinish];
      } @catch (NSException *e) { (void)e; g_exceptions++; }
    }
    settle(box);
    mark("req.close", logical.c_str(), seq);
    return;
  }

  if (isBlob && (plan.kind == PK_STREAM || plan.kind == PK_SSE)) {
    // THE CHUNKED PATH, and the one thing the production macOS handler
    // cannot do today: the response is sent now and the body is delivered
    // from a dispatch_after chain after startURLSchemeTask: has returned.
    mark((tag + ".materialised").c_str(), "producer chunk buffer",
         plan.kind == PK_SSE ? 0 : plan.chunk_bytes);
    mark((tag + ".respond_lazy").c_str(), plan.id.c_str(), plan.total);
    @try {
      NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc]
          initWithURL:[req URL]
           statusCode:200
          HTTPVersion:@"HTTP/1.1"
         headerFields:build_headers(
             [NSString stringWithUTF8String:plan.content_type.c_str()],
             plan.total, false, false, 0, 0, 0)];
      [task didReceiveResponse:r];
    } @catch (NSException *e) {
      (void)e;
      g_exceptions++;
      claim(box);
      settle(box);
      return;
    }
    schedule_chunk(box, plan, 0, tag);
    mark("req.close", logical.c_str(), seq);
    return;
  }

  NSData *bodyData = nil;
  NSString *contentType = @"application/octet-stream";
  int status = 200;
  bool partial = false;
  bool ranged = false;
  int64_t first = 0, last = 0, total = 0;

  if (isBlob) {
    contentType = [NSString stringWithUTF8String:plan.content_type.c_str()];
    if (plan.kind == PK_PNG) { plan.total = (int64_t)sizeof(TINY_PNG); }
    total = plan.total;
    ranged = plan.ranged;
    int64_t a = 0, b = 0;
    if (plan.ranged && range != nil &&
        parse_single_range(std::string([range UTF8String]), plan.total, a, b)) {
      int64_t count = b - a + 1;
      NSMutableData *m = [NSMutableData dataWithLength:(NSUInteger)count];
      fill_plan_range(plan, (unsigned char *)[m mutableBytes], a, count);
      bodyData = m;
      status = 206;
      partial = true;
      first = a;
      last = b;
      mark((tag + ".materialised").c_str(), "window (NSMutableData)",
           2 * count);
      mark((tag + ".respond206").c_str(), [range UTF8String], count);
    } else {
      NSMutableData *m = [NSMutableData dataWithLength:(NSUInteger)plan.total];
      fill_plan_range(plan, (unsigned char *)[m mutableBytes], 0, plan.total);
      bodyData = m;
      first = 0;
      last = plan.total - 1;
      mark((tag + ".materialised").c_str(), "whole body (NSMutableData)",
           2 * plan.total);
      mark((tag + ".respond200").c_str(), plan.id.c_str(), plan.total);
    }
  } else {
    NSString *file = [g_fixture_dir stringByAppendingPathComponent:
        [NSString stringWithUTF8String:logical.c_str()]];
    bodyData = [NSData dataWithContentsOfFile:file];
    if (bodyData == nil) {
      mark("req.notfound", logical.c_str(), seq);
      if (claim(box)) {
        @try {
          [task didFailWithError:[NSError errorWithDomain:@"cap12a" code:1
                                                 userInfo:nil]];
        } @catch (NSException *e) { (void)e; g_exceptions++; }
      }
      settle(box);
      return;
    }
    NSString *logicalNs = [NSString stringWithUTF8String:logical.c_str()];
    // the fixture carries two kinds of file and nothing else; this is not a
    // second MIME table and must never grow into one - PWebAssetMimeType is
    // the only one in this repository
    if ([logicalNs hasSuffix:@".html"]) {
      contentType = @"text/html; charset=utf-8";
    } else if ([logicalNs hasSuffix:@".js"]) {
      contentType = @"text/javascript; charset=utf-8";
    }
  }

  if (claim(box)) {
    @try {
      NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc]
          initWithURL:[req URL]
           statusCode:status
          HTTPVersion:@"HTTP/1.1"
         headerFields:build_headers(contentType, (int64_t)[bodyData length],
                                    partial, ranged, first, last, total)];
      [task didReceiveResponse:r];
      [task didReceiveData:bodyData];
      [task didFinish];
    } @catch (NSException *e) {
      (void)e;
      g_exceptions++;
    }
  }
  settle(box);
  mark("req.close", logical.c_str(), seq);
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
  g_stops++;
  TaskBox *found = nil;
  [g_tasks_lock lock];
  for (TaskBox *b in g_tasks) {
    if (b.task == task) { found = b; break; }
  }
  [g_tasks_lock unlock];
  if (found == nil) { return; }
  if (found.state == TS_SERVING) { g_stops_while_serving++; }
  // stopURLSchemeTask: CLAIMS the task too, and that is what makes "no
  // callback after stop" structural rather than a rule to remember
  claim(found);
  settle(found);
  mark("req.stopped", "", 0);
}

@end

// ------------------------------------------------------- the message bridge

@interface Cap12aBridge : NSObject <WKScriptMessageHandler>
@end

@implementation Cap12aBridge

- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
  NSString *name = [message name];
  id body = [message body];
  if ([name isEqualToString:@"cap12aMark"]) {
    g_marks++;
    NSString *label = [body isKindOfClass:[NSString class]] ? (NSString *)body : @"";
    const char *c = [label UTF8String];
    mark(c ? c : "", "", 0);
    std::string s(c ? c : "");
    if (s.size() > 6 && s.compare(s.size() - 6, 6, ".begin") == 0) {
      phase_begin(s.substr(0, s.size() - 6));
    } else if (s.size() > 4 && s.compare(s.size() - 4, 4, ".end") == 0) {
      phase_end();
    }
  } else if ([name isEqualToString:@"cap12aReport"]) {
    if (g_report_json == nil && [body isKindOfClass:[NSString class]]) {
      g_report_json = [(NSString *)body copy];
      mark("page.report", "", (int64_t)[g_report_json length]);
    }
    [NSApp terminate:nil];
  }
}

@end

// ------------------------------------------------------------------- main

// window.__cap12a_mark / __cap12a_report, with the SAME shape the two
// webview_bind bindings have on the other engines: a promise that resolves
// once the host has the message. The page never learns which engine it is on.
static NSString *const kShim =
    @"window.__cap12a_mark = function (label) {"
    @"  try { window.webkit.messageHandlers.cap12aMark.postMessage(String(label)); }"
    @"  catch (e) {}"
    @"  return Promise.resolve(null);"
    @"};"
    @"window.__cap12a_report = function (json) {"
    @"  try { window.webkit.messageHandlers.cap12aReport.postMessage(String(json)); }"
    @"  catch (e) {}"
    @"  return Promise.resolve(null);"
    @"};";

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    g_clock_base = (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)(ts.tv_nsec / 1000);

    const char *repo = getenv("PWEB_CAP12A_REPO");
    const char *out = getenv("PWEB_CAP12A_OUT");
    const char *cspPath = getenv("PWEB_CAP12A_CSP_FILE");
    int timeoutMs = 600000;
    if (getenv("PWEB_CAP12A_TIMEOUT_MS")) {
      timeoutMs = atoi(getenv("PWEB_CAP12A_TIMEOUT_MS"));
      if (timeoutMs < 10000 || timeoutMs > 1200000) { timeoutMs = 600000; }
    }
    if (!repo || !out || !cspPath) {
      fprintf(stderr, "CAP12A_FAIL reason=PWEB_CAP12A_REPO, _OUT and "
                      "_CSP_FILE must be set (see run_cap12a_macos.sh)\n");
      return 2;
    }

    g_timeline_lock = [[NSLock alloc] init];
    g_tasks_lock = [[NSLock alloc] init];
    g_tasks = [[NSMutableArray alloc] init];

    g_fixture_dir = [[NSString stringWithUTF8String:repo]
        stringByAppendingPathComponent:@"test/cap12a/fixture"];
    g_out_path = [NSString stringWithUTF8String:out];
    // THE CSP IS READ, NOT RETYPED. It is extracted from
    // src/security/pweb.navigation.policy.pas by the run script, so this
    // probe cannot drift from the shipped policy the other two legs carry.
    g_csp = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:cspPath]
                                      encoding:NSUTF8StringEncoding
                                         error:nil];
    if (g_csp == nil) {
      fprintf(stderr, "CAP12A_FAIL reason=cannot read the CSP file\n");
      return 2;
    }
    g_csp = [g_csp stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    mark("host.start", "macos", process_rss_bytes());
    g_rss_run = true;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      long long lastMarked = 0;
      while (g_rss_run.load()) {
        int64_t v = process_rss_bytes();
        if (v > 0) {
          if (v > g_rss_max.load()) { g_rss_max = v; }
          g_rss_samples++;
          if (v > lastMarked + 8 * 1024 * 1024 ||
              v < lastMarked - 8 * 1024 * 1024) {
            mark("rss", "", v);
            lastMarked = v;
          }
        }
        usleep(10000);
      }
    });

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    Cap12aSchemeHandler *handler = [[Cap12aSchemeHandler alloc] init];
    [cfg setURLSchemeHandler:handler forURLScheme:@"pweb"];
    Cap12aBridge *bridge = [[Cap12aBridge alloc] init];
    WKUserContentController *ucc = [cfg userContentController];
    [ucc addScriptMessageHandler:bridge name:@"cap12aMark"];
    [ucc addScriptMessageHandler:bridge name:@"cap12aReport"];
    [ucc addUserScript:[[WKUserScript alloc]
                           initWithSource:kShim
                            injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                         forMainFrameOnly:YES]];

    NSRect frame = NSMakeRect(0, 0, 900, 650);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    [window setTitle:@"PWeb CAP-12A blob probe"];
    WKWebView *webView = [[WKWebView alloc] initWithFrame:frame configuration:cfg];
    [window setContentView:webView];
    [window makeKeyAndOrderFront:nil];

    [webView loadRequest:[NSURLRequest requestWithURL:
                             [NSURL URLWithString:@"pweb://app/"]]];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)timeoutMs * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
      fprintf(stderr, "CAP12A_FAIL reason=watchdog fired after %d ms\n",
              timeoutMs);
      [NSApp terminate:nil];
    });

    [NSApp run];

    g_rss_run = false;
    mark("host.stop", "", process_rss_bytes());

    const char *arch =
#if defined(__aarch64__)
        "macos-arm64";
#else
        "macos-x86_64";
#endif

    std::string page = g_report_json != nil
        ? std::string([g_report_json UTF8String]) : std::string("null");
    std::string failures;
    if (g_report_json == nil) { failures = "no page report arrived"; }
    if (g_marks.load() == 0) {
      if (!failures.empty()) { failures += "; "; }
      failures += "no page mark arrived - the bound seam never worked";
    }
    if (g_timeline_dropped.load() > 0) {
      if (!failures.empty()) { failures += "; "; }
      failures += "the timeline overflowed";
    }

    std::string json = "{\n";
    json += "  \"schema\": 1,\n";
    json += std::string("  \"target\": \"") + arch + "\",\n";
    json += "  \"csp\": " + json_quote(std::string([g_csp UTF8String])) + ",\n";
    json += "  \"blob_prefix\": \"_pweb/blob/\",\n";
    json += std::string("  \"overall\": \"") +
            (failures.empty() ? "COMPLETE" : "INCOMPLETE") + "\",\n";
    if (!failures.empty()) {
      json += "  \"failures\": " + json_quote(failures) + ",\n";
    }
    char facts[640];
    snprintf(facts, sizeof(facts),
             "  \"engine_facts\": {\n"
             "    \"methods_seen\": \"%s\",\n"
             "    \"requests_with_headers\": %d,\n"
             "    \"requests_with_body\": %d,\n"
             "    \"body_as_httpbody\": %d,\n"
             "    \"body_as_httpbodystream\": %d,\n"
             "    \"handler_calls_off_main_thread\": %d,\n"
             "    \"stop_arrivals\": %d,\n"
             "    \"stops_while_serving\": %d,\n"
             "    \"suppressed_terminals\": %d,\n"
             "    \"caught_exceptions\": %d,\n"
             "    \"second_authority_requests\": %d\n"
             "  },\n",
             g_methods_seen.c_str(), g_requests_with_headers.load(),
             g_requests_with_body.load(), g_body_as_data.load(),
             g_body_as_stream.load(), g_handler_off_main.load(),
             g_stops.load(), g_stops_while_serving.load(),
             g_suppressed.load(), g_exceptions.load(),
             g_second_authority.load());
    json += facts;
    char nums[256];
    snprintf(nums, sizeof(nums),
             "  \"marks\": %d,\n  \"timeline_events\": %zu,\n"
             "  \"timeline_dropped\": %d,\n  \"rss_samples\": %d,\n",
             g_marks.load(), g_timeline.size(), g_timeline_dropped.load(),
             g_rss_samples.load());
    json += nums;
    json += "  \"rss_phases\": [" + g_rss_phases + "],\n";
    json += "  \"timeline\": " + timeline_json() + ",\n";
    json += "  \"page\": " + page + "\n}\n";

    FILE *f = fopen(out, "wb");
    if (!f) {
      fprintf(stderr, "CAP12A_FAIL reason=cannot write %s\n", out);
      return 1;
    }
    fwrite(json.data(), 1, json.size(), f);
    fclose(f);
    fprintf(stdout, "CAP12A_OUT path=%s\n", out);

    if (!failures.empty()) {
      fprintf(stderr, "CAP12A_FAIL reason=%s\n", failures.c_str());
      return 1;
    }
    fprintf(stdout, "CAP12A_PASS marks=%d events=%zu\n", g_marks.load(),
            g_timeline.size());
    return 0;
  }
}
