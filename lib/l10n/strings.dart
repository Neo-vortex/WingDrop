import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../blocs/app_cubit.dart';

/// All user-facing copy, English and Persian side by side. Tone: a friend
/// helping you out, never a manual.
class S {
  const S(this.fa);

  final bool fa;

  static S of(BuildContext context) => S(context.watch<AppCubit>().state.lang == 'fa');

  String _t(String en, String fa) => this.fa ? fa : en;

  /// Persian digits in Persian mode.
  String n(Object v) {
    final s = '$v';
    if (!fa) return s;
    const d = '۰۱۲۳۴۵۶۷۸۹';
    return s.replaceAllMapped(RegExp(r'[0-9]'), (m) => d[int.parse(m[0]!)]).replaceAll('.', '٫');
  }

  // ---------------------------------------------------------------- language & onboarding
  String get chooseLanguage => _t('Pick your language', 'زبانت رو انتخاب کن');
  String get languageHint => _t('You can change it later in settings.', 'بعداً هم از تنظیمات می‌تونی عوضش کنی.');
  String get next => _t('Next', 'بعدی');
  String get skip => _t('Skip', 'رد شو');
  String get letsGo => _t("Let's go!", 'بزن بریم!');
  String get ob1Title => _t('Hey there! 👋', 'سلام! 👋');
  String get ob1Body => _t(
        'WingDrop moves your photos, videos, music, apps and files between phones. No internet, no cables, no fuss.',
        'وینگ‌دراپ عکس، فیلم، آهنگ، برنامه و هر فایلی رو بین گوشی‌ها جابه‌جا می‌کنه. بدون اینترنت، بدون سیم، بدون دردسر.',
      );
  String get ob2Title => _t('Seriously fast ⚡', 'واقعاً سریع ⚡');
  String get ob2Body => _t(
        'It uses the fastest Wi-Fi your phone has and every core of its brain. Big videos fly over in seconds.',
        'از سریع‌ترین وای‌فای گوشیت و همه‌ی هسته‌های پردازنده‌ش استفاده می‌کنه. فیلمای سنگین تو چند ثانیه می‌رسن.',
      );
  String get ob3Title => _t('Simple as can be 🌿', 'ساده‌تر از این نمی‌شه 🌿');
  String get ob3Body => _t(
        'One phone taps Receive and shows a code. The other taps Send and scans it. That\'s literally it.',
        'یه گوشی «دریافت» رو می‌زنه و یه کد نشون می‌ده، اون یکی «ارسال» رو می‌زنه و کد رو اسکن می‌کنه. همین!',
      );

  // ---------------------------------------------------------------- home
  String get appName => _t('WingDrop', 'وینگ‌دراپ');
  String get tagline => _t('Share anything with the phone next to you.', 'هرچی دوست داری با گوشی بغلی به اشتراک بذار.');
  String get send => _t('Send', 'ارسال');
  String get sendSub => _t('Photos, videos, music, apps, files', 'عکس، فیلم، آهنگ، برنامه، فایل');
  String get receive => _t('Receive', 'دریافت');
  String get receiveSub => _t('Show a code, the other phone scans it', 'یه کد نشون بده تا اون یکی اسکنش کنه');
  String get benchmark => _t('Benchmark', 'بنچمارک');
  String get settings => _t('Settings', 'تنظیمات');

  // ---------------------------------------------------------------- picker
  String get pickTitle => _t('What are we sending?', 'چی می‌خوای بفرستی؟');
  String get photos => _t('Photos', 'عکس‌ها');
  String get videos => _t('Videos', 'فیلم‌ها');
  String get music => _t('Music', 'آهنگ‌ها');
  String get apps => _t('Apps', 'برنامه‌ها');
  String get files => _t('Files', 'فایل‌ها');
  String get addFiles => _t('Add files', 'اضافه کردن فایل');
  String get nothingHere => _t('Nothing here yet', 'فعلاً چیزی اینجا نیست');
  String selected(int n) => _t('${this.n(n)} picked', '${this.n(n)} تا انتخاب شد');
  String get noMediaAccess => _t(
        "I can't see your media yet, so there's nothing to show here.",
        'هنوز به عکس و فیلمات دسترسی ندارم، واسه همین چیزی نمی‌تونم نشون بدم.',
      );
  String get letMeSee => _t('Let me see them', 'بذار ببینمشون');

  // ---------------------------------------------------------------- send flow
  String sendingN(int n) => _t('Sending ${this.n(n)} item${n == 1 ? '' : 's'}', 'ارسال ${this.n(n)} مورد');
  String heicTitle(int n) => _t('${this.n(n)} HEIC photo${n == 1 ? '' : 's'} in there', '${this.n(n)} تا عکس HEIC این وسطه');
  String get heicBody => _t(
        "Some phones and computers can't open HEIC. Want me to turn them into JPEG on the way? Dates and location stay put.",
        'بعضی گوشی‌ها و کامپیوترها HEIC رو باز نمی‌کنن. می‌خوای سر راه تبدیلشون کنم به JPEG؟ تاریخ و لوکیشن عکس‌ها سر جاشون می‌مونن.',
      );
  String get heicConvert => _t('Yes, make them JPEG', 'آره، JPEG‌شون کن');
  String get heicKeep => _t('Nah, keep HEIC', 'نه، همون HEIC بمونه');
  String shrinkTitle(int n) => _t('Make ${this.n(n)} media file${n == 1 ? '' : 's'} lighter?', '${this.n(n)} تا فایل رسانه‌ای رو سبک‌تر کنم؟');
  String get shrinkBody => _t(
        'Smaller files arrive faster and take less space on the other phone. Regular files and apps always go as they are.',
        'فایل سبک‌تر زودتر می‌رسه و جای کمتری تو اون گوشی می‌گیره. فایل‌های معمولی و برنامه‌ها همیشه همون‌جوری که هستن می‌رن.',
      );
  String get shrinkOriginal => _t('Send as is', 'همین‌جوری بفرست');
  String get shrinkOriginalSub => _t('Full original quality, no waiting', 'با همون کیفیت اصلی، بدون معطلی');
  String get shrinkLight => _t('A bit lighter', 'یه کم سبک‌تر');
  String get shrinkLightSub => _t('Hard to tell apart from the original', 'تقریباً با اصلش فرقی نداره');
  String get shrinkSmall => _t('Much lighter', 'خیلی سبک‌تر');
  String get shrinkSmallSub => _t('Smallest size that still looks and sounds fine', 'کمترین حجمی که هنوز خوب دیده و شنیده می‌شه');
  String get shrinking => _t('Making things lighter…', 'دارم فایل‌ها رو سبک‌تر می‌کنم…');
  String shrinkingRest(int n) => _t(
        n == 1 ? 'Shrinking one more…' : 'Shrinking $n more…',
        n == 1 ? 'دارم یکی دیگه رو سبک می‌کنم…' : 'دارم $n تای دیگه رو سبک می‌کنم…',
      );
  String shrinkingRestSub(int pct) => _t('$pct% · it goes the moment it\'s ready', '$pct٪ · همین که آماده شد می‌ره');
  String prepLine(int n, int pct) => _t(
        n == 1 ? 'Shrinking one file in the background · $pct%' : 'Shrinking $n files in the background · $pct%',
        n == 1 ? 'یه فایل پشت صحنه داره سبک می‌شه · $pct٪' : '$n تا فایل پشت صحنه دارن سبک می‌شن · $pct٪',
      );
  String get shrinkingSub => _t('Using the phone\'s video hardware, hang tight', 'با سخت‌افزار ویدیوی گوشی، یه کم صبر کن');
  String get shrinkSetting => _t('Make media lighter', 'سبک‌تر کردن رسانه‌ها');
  String get shrinkAsk => _t('Ask me', 'بپرس');
  String get addFolder => _t('Add folder', 'اضافه کردن پوشه');
  String get converting => _t('Turning photos into JPEG…', 'دارم عکس‌ها رو JPEG می‌کنم…');
  String get convertingSub => _t('All cores on it, won\'t take long', 'همه‌ی هسته‌ها دارن کار می‌کنن، زیاد طول نمی‌کشه');
  String get scanTitle => _t('Now scan the code on the other phone', 'حالا کدی که رو گوشی اون یکیه رو اسکن کن');
  String get openScanner => _t('Open scanner', 'باز کردن اسکنر');
  String get notOurCode => _t("Hmm, that code isn't from WingDrop", 'اِ، این کد مال وینگ‌دراپ نیست');
  String get connecting => _t('Saying hi to the other phone…', 'داریم به اون گوشی سلام می‌کنیم…');
  String get radarHint => _t(
        'Make sure the other phone is on its Receive screen, close by.',
        'مطمئن شو اون گوشی روی صفحه‌ی دریافت و نزدیکه.',
      );
  String get btOffTitle => _t('Bluetooth is off', 'بلوتوث خاموشه');
  String get btOffBody => _t('With it on, nearby phones show up in a second.', 'اگه روشن باشه، گوشی‌های اطراف تو یه ثانیه پیدا می‌شن.');
  String get turnOn => _t('Turn on', 'روشن کن');
  String get receiverBtOff => _t(
        'Bluetooth is off, so senders find you a bit slower. The code always works.',
        'بلوتوث خاموشه، واسه همین فرستنده‌ها یه کم دیرتر پیدات می‌کنن. کد همیشه کار می‌کنه.',
      );
  String get cancel => _t('Cancel', 'لغو');
  String get pickAnother => _t('Choose again', 'دوباره انتخاب کن');
  String get showDetails => _t('Show details', 'نمایش جزئیات');
  String get nerdLog => _t('Nerd log', 'گزارش فنی');
  String get pauseLog => _t('Pause', 'مکث');
  String get resumeLog => _t('Resume', 'ادامه');
  String get clearLog => _t('Clear', 'پاک کردن');
  String get logEmpty => _t('Nothing logged yet', 'هنوز چیزی ثبت نشده');
  String get connectionLog => _t('Connection log', 'گزارش اتصال');
  String get copy => _t('Copy', 'کپی');
  String get copied => _t('Copied', 'کپی شد');
  String get theOtherPhone => _t('the other phone', 'اون گوشی');
  String stageJoining(String who) => _t("Joining $who's Wi-Fi…", 'دارم به وای‌فای $who وصل می‌شم…');
  String get stageFallback => _t('Trying another way to connect…', 'دارم از یه راه دیگه وصل می‌شم…');
  String get stageSystemPrompt => _t(
        'Android may ask you to confirm the connection. Tap Connect if you see it.',
        'ممکنه اندروید ازت بپرسه که وصل بشه یا نه. اگه دیدی، «اتصال» رو بزن.',
      );
  String stageReaching(String who) => _t('Reaching $who…', 'دارم به $who می‌رسم…');
  String get errCameraTitle => _t("The camera didn't start", 'دوربین روشن نشد');
  String get errCameraBody => _t(
        'Another app might be using it. Close it and try again, or pick the phone from the nearby list.',
        'شاید یه برنامه‌ی دیگه داره ازش استفاده می‌کنه. ببندش و دوباره امتحان کن، یا گوشی رو از لیست اطراف انتخاب کن.',
      );
  String get errVpnTitle => _t('A VPN is in the way', 'یه VPN سر راهه');
  String get errJoinTitle => _t("Couldn't join the other phone's Wi-Fi", 'نتونستم به وای‌فای اون گوشی وصل بشم');
  String get errJoinBody => _t(
        'Bring the phones closer and make sure the other one is still on the Receive screen. If Android showed a popup, it needs a Connect.',
        'گوشی‌ها رو نزدیک‌تر کن و مطمئن شو اون یکی هنوز روی صفحه‌ی دریافت‌ه. اگه اندروید پیامی نشون داد، باید «اتصال» رو بزنی.',
      );
  String get errUnreachableTitle => _t('Connected, but no answer', 'وصل شدم، ولی جوابی نیومد');
  String get errUnreachableBody => _t(
        "We joined its Wi-Fi but WingDrop there didn't pick up. Is the Receive screen still open on the other phone?",
        'به وای‌فاش وصل شدیم ولی وینگ‌دراپ اونجا جواب نداد. صفحه‌ی دریافت هنوز روی اون گوشی بازه؟',
      );
  String get errRefusedTitle => _t('That code has expired', 'این کد دیگه معتبر نیست');
  String get errRefusedBody => _t(
        'The other phone opened Receive again, so it has a new code. Scan the one on its screen now.',
        'اون گوشی دوباره صفحه‌ی دریافت رو باز کرده و کد جدید داره. کدی که الان روی صفحه‌شه رو اسکن کن.',
      );
  String get errPeerOutdatedTitle => _t('The other phone needs an update', 'اون گوشی باید به‌روز بشه');
  String get errPeerOutdatedBody => _t(
        'It has an older WingDrop that speaks a different language. Update it there and try again.',
        'یه نسخه‌ی قدیمی‌تر از وینگ‌دراپ داره که زبونش فرق می‌کنه. اونجا به‌روزش کن و دوباره امتحان کن.',
      );
  String get errSelfOutdatedTitle => _t('This phone needs an update', 'این گوشی باید به‌روز بشه');
  String get errSelfOutdatedBody => _t(
        'The other phone has a newer WingDrop. Update this one and try again.',
        'اون گوشی نسخه‌ی جدیدتری از وینگ‌دراپ داره. این یکی رو به‌روز کن و دوباره امتحان کن.',
      );
  String get errNoAnswerTitle => _t("The other phone didn't answer", 'اون گوشی جواب نداد');
  String get errNoAnswerBody => _t(
        "Maybe nobody tapped Accept in time. Try again and keep an eye on the other phone's screen.",
        'شاید کسی به‌موقع «قبول» رو نزد. دوباره امتحان کن و حواست به صفحه‌ی اون گوشی باشه.',
      );
  String get errGenericTitle => _t('Something went wrong', 'یه جای کار ایراد داشت');
  String get tryAgain => _t('Try again', 'دوباره امتحان کن');
  String get done => _t('Done', 'تموم');
  String get stopSendingQ => _t('Stop sending?', 'ارسال رو متوقف کنم؟');
  String get stopReceivingQ => _t('Stop receiving?', 'دریافت رو متوقف کنم؟');
  String get keepGoing => _t('Keep going', 'نه، ادامه بده');
  String get stop => _t('Stop', 'آره، وایسا');

  String wantsToSend(String who, int files, String size) => _t(
        '$who wants to send you ${n(files)} item${files == 1 ? '' : 's'} ($size)',
        '$who می‌خواد ${n(files)} مورد ($size) برات بفرسته',
      );
  String get acceptQ => _t('Let it in?', 'قبول می‌کنی؟');
  String get accept => _t('Accept', 'قبول');
  String get decline => _t('Not now', 'الان نه');
  String get declined => _t('They said not now. Maybe try again in a bit? 🙂', 'فعلاً قبول نکرد. شاید یه کم بعد دوباره امتحان کنی؟ 🙂');
  String waitingFor(String who) => _t('Waiting for $who to say yes…', 'منتظریم $who قبول کنه…');
  String get lookAround => _t('Find phones nearby', 'پیدا کردن گوشی‌های اطراف');
  String get lookingAround => _t('Looking around…', 'دارم این اطراف رو می‌گردم…');
  String get orScan => _t('Or scan their code', 'یا کدش رو اسکن کن');
  String get radarNote => _t(
        'Tap someone to send. They\'ll be asked to accept.',
        'روی یکی بزن تا بفرستی. ازش می‌پرسیم که قبول می‌کنه یا نه.',
      );
  String get nearbyTitle => _t('Nearby, ready to receive', 'این اطراف، آماده‌ی دریافت');
  String get encrypted => _t('Encrypted', 'رمزشده');
  String get compressed => _t('Compressed', 'فشرده');
  String scanTheirCode(String who) => _t("Scan $who's code to connect", 'برای وصل شدن، کد $who رو اسکن کن');

  // ---------------------------------------------------------------- identity
  String get pickBuddyTitle => _t('Pick your buddy 🐾', 'رفیقت رو انتخاب کن 🐾');
  String get pickBuddyBody => _t(
        'This little friend shows up on the other phone so they know it\'s you.',
        'این رفیق کوچولو روی گوشی طرف مقابل نشون داده می‌شه که بدونه تویی.',
      );
  String get nickname => _t('Nickname (optional)', 'اسم مستعار (اختیاری)');
  String get nicknameHint => _t('Latin letters travel best over Wi-Fi', 'حروف انگلیسی بهتر از وای‌فای رد می‌شن');
  String get you => _t('You', 'خودت');

  // ---------------------------------------------------------------- receive
  String get receiveTitle => _t('Ready to receive', 'آماده‌ی دریافت');
  String get settingUp => _t('Getting the Wi-Fi ready…', 'دارم وای‌فای رو آماده می‌کنم…');
  String get scanThis => _t('Scan this with the sending phone', 'با گوشی فرستنده این کد رو اسکن کن');
  String get tapToEnlarge => _t('Tap the code to make it bigger', 'برای بزرگ‌تر شدن روی کد بزن');
  String get tapToClose => _t('Tap anywhere to close', 'هرجا بزنی بسته می‌شه');
  String get waiting => _t('Waiting for the other phone…', 'منتظر اون یکی گوشی‌ایم…');
  String get networkDetails => _t('Network details', 'جزئیات شبکه');
  String get receivedFiles => _t('Received', 'دریافت‌شده‌ها');
  String get open => _t('Open', 'باز کن');
  String get install => _t('Install', 'نصب');
  String get delete => _t('Delete', 'حذف');
  String get tapToOpen => _t('Tap a file to open or delete it', 'روی هر فایل بزن تا بازش کنی یا پاکش کنی');
  String get stillArriving => _t('Still arriving…', 'هنوز داره میاد…');
  String get deleted => _t('Deleted', 'حذف شد');
  String get deleteQ => _t('Delete this?', 'حذفش کنم؟');
  String deleteBody(String name) => _t('"$name" will be gone from this phone for good.', '«$name» برای همیشه از این گوشی پاک می‌شه.');
  String get keepIt => _t('Keep it', 'نه، بمونه');
  String get couldntStart => _t("Couldn't start receiving", 'نشد دریافت رو شروع کنم');
  String get wifiOff => _t('Wi-Fi is off. Flip it on and try again?', 'وای‌فای خاموشه. روشنش می‌کنی دوباره امتحان کنیم؟');
  String get openWifi => _t('Wi-Fi settings', 'تنظیمات وای‌فای');
  String get senderWifiOffTitle => _t('Wi-Fi is taking a nap 😴', 'وای‌فای خوابه 😴');
  String get senderWifiOffBody => _t(
        'I need Wi-Fi on to reach the other phone (no internet needed). Flip it on and I\'ll carry on by myself.',
        'برای رسیدن به اون گوشی وای‌فای باید روشن باشه (اینترنت لازم نیست). روشنش کن، بقیه‌ش با من.',
      );
  String get radarWifiOff => _t(
        'Turn on Wi-Fi to see phones nearby. No internet needed, Wi-Fi Direct just lives on the Wi-Fi chip.',
        'برای دیدن گوشی‌های اطراف وای‌فای رو روشن کن. اینترنت لازم نیست، وای‌فای دایرکت فقط روی تراشه‌ی وای‌فای کار می‌کنه.',
      );
  String get vpnHint => _t(
        'Looks like a VPN is catching the connection. Pause it for a moment and try again?',
        'انگار یه VPN ارتباط رو قاپیده. یه لحظه خاموشش کن و دوباره امتحان کن؟',
      );
  String get turnOnWifi => _t('Turn on Wi-Fi', 'روشن کردن وای‌فای');
  String get noAppToOpen => _t('No app here can open that one', 'هیچ برنامه‌ای نیست که اینو باز کنه');

  // ---------------------------------------------------------------- transfer
  String get sendingNow => _t('Sending now', 'الان داره می‌ره');
  String get receivingNow => _t('Receiving now', 'الان داره میاد');
  String itemsOf(int a, int b) => _t('${n(a)} of ${n(b)}', '${n(a)} از ${n(b)}');
  String get items => _t('items', 'مورد');
  String get allSent => _t('All sent! 🎉', 'همه رفت! 🎉');
  String get allReceived => _t('All here! 🎉', 'همه رسید! 🎉');
  String get stopped => _t('Stopped', 'متوقف شد');
  String get paused => _t('Something got in the way', 'یه چیزی وسط کار گیر کرد');
  String get interrupted => _t('The connection dropped. Move the phones closer and try again?',
      'ارتباط قطع شد. گوشی‌ها رو نزدیک‌تر کن و دوباره امتحان کن؟');
  String get connectingShort => _t('Connecting…', 'در حال وصل شدن…');
  String get estimating => _t('Figuring out the time…', 'دارم زمانش رو حساب می‌کنم…');
  String get almostDone => _t('Almost done', 'تقریباً تمومه');
  String bytesOf(String a, String b) => _t('$a of $b', '$a از $b');
  String doneIn(String size, String time, String rate) => _t('$size in $time · $rate', '$size در $time · $rate');
  String get details => _t('Details', 'جزئیات');
  String get chat => _t('Chat', 'گپ');
  String get chatHint => _t('Say something nice…', 'یه چیز قشنگ بگو…');
  String get chatEmpty => _t('Say hi while the files fly over 👋', 'تا فایل‌ها برسن یه سلامی بکن 👋');
  String get chatClosed => _t('Chat ends when the transfer does', 'گپ با تموم شدن انتقال تموم می‌شه');
  String get reply => _t('Reply', 'جواب');
  String flewOver(String time, bool underASecond) => underASecond
      ? _t('Flew over in under a second', 'کمتر از یه ثانیه رسید')
      : _t('Flew over in $time', 'تو $time رسید');
  String peak(String v) => _t('peak $v', 'اوج $v');
  String get resume => _t('Pick up where we left off', 'از همون‌جا که موند ادامه بده');
  String get resumedFrom => _t('Already there (resumed)', 'از قبل رسیده بود (ادامه)');
  String get retryingSoon => _t('Trying again in a moment…', 'یه لحظه دیگه دوباره امتحان می‌کنم…');
  String get acceptRemember => _t('Accept and remember them', 'قبول، و یادت بمونه');
  String get trusted => _t('Trusted', 'مورد اعتماد');
  String get trustedTitle => _t('Trusted buddies', 'رفقای مورد اعتماد');
  String get trustedHint => _t(
        'They connect with one tap, no code and no question. Tap × to forget one.',
        'با یه تَپ وصل می‌شن، بدون کد و بدون سوال. برای فراموش کردن روی × بزن.',
      );
  String get noTrusted => _t('Nobody yet. Scan someone\'s code once and they\'ll show up here.',
      'هنوز کسی نیست. یه بار کد کسی رو اسکن کن تا اینجا بیاد.');
  String get sendToSelected => _t('Send to them', 'بفرست براشون');
  String selectedPeers(int n) => _t('${this.n(n)} phones picked', '${this.n(n)} گوشی انتخاب شد');
  String get pickSeveral => _t('Tip: long-press to pick several phones', 'نکته: برای انتخاب چند گوشی، نگه دار');
  String sendingTo(int n) => _t('Sending to ${this.n(n)} phones', 'ارسال به ${this.n(n)} گوشی');
  String get oneAfterAnother => _t(
        'Wi-Fi Direct phones get their turn one after another; phones on the same network all at once.',
        'گوشی‌های وای‌فای دایرکت به نوبت، و گوشی‌هایی که روی یک شبکه‌ان همه با هم.',
      );
  String get waitingTurn => _t('Waiting for its turn', 'منتظر نوبت');
  String get streams => _t('Parallel streams', 'جریان‌های موازی');
  String get encryption => _t('Encryption', 'رمزنگاری');
  String get compression => _t('Compression', 'فشرده‌سازی');
  String get avgSpeed => _t('Average speed', 'میانگین سرعت');
  String get off => _t('Off', 'خاموش');

  /// Gentle time phrases. [forItem] = "for this one" style.
  String eta(double secs, {bool forItem = false}) {
    if (secs.isNaN || secs.isInfinite) return estimating;
    if (secs < 10) return almostDone;
    final suffixEn = forItem ? 'for this one' : 'left';
    final suffixFa = forItem ? 'برای این یکی' : 'مونده';
    if (secs < 50) return _t('Less than a minute $suffixEn', 'کمتر از یه دقیقه $suffixFa');
    if (secs < 90) return _t('About a minute $suffixEn', 'حدود یه دقیقه $suffixFa');
    final mins = secs / 60;
    if (mins < 60) {
      final m = mins < 10 ? mins.round() : (mins / 5).round() * 5;
      return _t('About $m minutes $suffixEn', 'حدود ${n(m)} دقیقه $suffixFa');
    }
    final h = mins / 60;
    if (h < 1.5) return _t('About an hour $suffixEn', 'حدود یه ساعت $suffixFa');
    return _t('About ${h.round()} hours $suffixEn', 'حدود ${n(h.round())} ساعت $suffixFa');
  }

  // ---------------------------------------------------------------- permissions
  String get permNearbyTitle => _t('Can I peek at nearby Wi-Fi? 📡', 'اجازه هست وای‌فای‌های اطراف رو ببینم؟ 📡');
  String get permNearbyBody => _t(
        'To link up with the other phone directly I need to talk to nearby Wi-Fi devices. I don\'t track where you are, promise.',
        'برای اینکه مستقیم به اون گوشی وصل شم باید با دستگاه‌های وای‌فای اطراف حرف بزنم. قول می‌دم مکانت رو دنبال نکنم.',
      );
  String get btAskTitle => _t('Mind turning on Bluetooth? 🔵', 'بلوتوث رو روشن کنیم؟ 🔵');
  String get btAskBody => _t(
        'It lets the two phones spot each other in about a second instead of a long wait. Only a tiny "I\'m here" signal goes over it; your files still fly over Wi-Fi.',
        'اینطوری دو تا گوشی تو یه ثانیه همدیگه رو پیدا می‌کنن، نه بعد از یه انتظار طولانی. فقط یه سیگنال کوچولوی «من اینجام» ازش رد می‌شه؛ فایلات همچنان با وای‌فای می‌رن.',
      );
  String get permMediaTitle => _t('Mind if I look at your media? 🖼️', 'اجازه می‌دی عکس و فیلمات رو ببینم؟ 🖼️');
  String get permMediaBody => _t(
        'That\'s how I can show your photos, videos and music so you can pick what to send. Nothing leaves your phone unless you send it.',
        'اینطوری می‌تونم عکس و فیلم و آهنگات رو نشونت بدم که انتخاب کنی. تا خودت نفرستی هیچی از گوشیت بیرون نمی‌ره.',
      );
  String get permNotifTitle => _t('Want a heads-up? 🔔', 'می‌خوای خبرت کنم؟ 🔔');
  String get permNotifBody => _t(
        'I\'ll show a quiet little notification while a transfer runs, so it keeps going even if you switch apps.',
        'موقع انتقال یه نوتیفیکیشن کوچیک و بی‌سروصدا نشون می‌دم، که اگه رفتی سراغ یه برنامه‌ی دیگه هم کار ادامه پیدا کنه.',
      );
  String get permCameraTitle => _t('Borrow your camera for a sec? 📷', 'یه لحظه دوربینت رو قرض می‌دی؟ 📷');
  String get permCameraBody => _t(
        'Just to scan the code on the other phone. No photos, no recording, nothing saved.',
        'فقط برای اسکن کردن کد روی اون گوشی. نه عکسی می‌گیرم، نه فیلمی، نه چیزی ذخیره می‌کنم.',
      );
  String get needCamera => _t('I need the camera to scan the code', 'برای اسکن کد به دوربین نیاز دارم');
  String get pointAtCode => _t('Point at the code on the other phone', 'دوربین رو بگیر سمت کد روی اون گوشی');
  String get sure => _t('Sure, go ahead', 'باشه، حتماً');
  String get notNow => _t('Not now', 'الان نه');
  String get permBlockedTitle => _t('No worries! 🙂', 'اشکالی نداره! 🙂');
  String get permBlockedBody => _t(
        'Looks like this one got switched off. If you change your mind, you can turn it on in Settings, it takes two taps.',
        'انگار این دسترسی خاموش شده. اگه نظرت عوض شد از تنظیمات روشنش کن، دو تا تَپ بیشتر نیست.',
      );
  String get openSettings => _t('Open Settings', 'باز کردن تنظیمات');
  String get needNearby => _t('I need the nearby Wi-Fi permission to connect', 'برای وصل شدن به اجازه‌ی وای‌فای‌های اطراف نیاز دارم');

  // ---------------------------------------------------------------- settings
  String get presets => _t('Presets', 'حالت‌های آماده');
  String get presetMax => _t('Max speed', 'حداکثر سرعت');
  String get presetMaxBody => _t(
        'Fastest Wi-Fi band your phones share (6 GHz or 5 GHz), WPA3 when possible, one stream per big core. No extra overhead.',
        'سریع‌ترین باند وای‌فای مشترک دو گوشی (۶ یا ۵ گیگاهرتز)، WPA3 اگه بشه، برای هر هسته‌ی قوی یه جریان. بدون هیچ سربار اضافه.',
      );
  String get presetCompat => _t('Compatibility', 'سازگاری');
  String get presetCompatBody => _t(
        'Plain 2.4 GHz with WPA2 that every phone can join, 2 streams, no compression or encryption. Want an open hotspot with no password? Make one in system settings and pick "Same network".',
        'وای‌فای ساده‌ی ۲٫۴ گیگاهرتز با WPA2 که همه‌ی گوشی‌ها بهش وصل می‌شن، دو جریان، بدون فشرده‌سازی و رمزنگاری. هات‌اسپات بدون رمز می‌خوای؟ از تنظیمات گوشی بسازش و «همون شبکه» رو انتخاب کن.',
      );
  String get presetSecure => _t('Secure', 'امن');
  String get presetSecureBody => _t(
        'Fast link plus end-to-end encryption through the Vortex tunnel, with smart on-the-fly compression.',
        'اتصال سریع به‌علاوه‌ی رمزنگاری سرتاسری با تونل ورتکس، همراه با فشرده‌سازی هوشمند در لحظه.',
      );
  String get presetCustom => _t('Advanced', 'پیشرفته');
  String get presetCustomBody => _t('Tweak every knob yourself.', 'همه‌چی رو خودت تنظیم کن.');
  String get advanced => _t('Advanced', 'پیشرفته');
  String get advancedHint => _t('Touching anything here switches you to Advanced.', 'به هرکدوم دست بزنی می‌ری رو حالت پیشرفته.');
  String get link => _t('Connection', 'نوع اتصال');
  String get linkP2p => _t('Wi-Fi Direct', 'وای‌فای دایرکت');
  String get linkLohs => _t('Hotspot', 'هات‌اسپات');
  String get linkLan => _t('Same network', 'همون شبکه');
  String get band => _t('Wi-Fi band', 'باند وای‌فای');
  String get bandBest => _t('Best', 'بهترین');
  String get bandAuto => _t('Auto', 'خودکار');
  String get wifiSecurity => _t('Wi-Fi security', 'امنیت وای‌فای');
  String get e2e => _t('End-to-end encryption', 'رمزنگاری سرتاسری');
  String get e2eSub => _t(
        'AEGIS-128L on the AES hardware (XChaCha20-Poly1305 on older chips), keys from an X25519 Vortex tunnel',
        'AEGIS-128L روی سخت‌افزار AES (روی تراشه‌های قدیمی‌تر XChaCha20-Poly1305)، با کلیدهای تونل ورتکس X25519',
      );
  String get compressionAuto => _t('Smart', 'هوشمند');
  String get compressionAll => _t('Everything', 'همه‌چی');
  String get streamsAuto => _t('Auto', 'خودکار');
  String get chunk => _t('Chunk size', 'اندازه‌ی تکه');
  String get sockBuf => _t('Socket buffer', 'بافر سوکت');
  String get depth => _t('Pipeline depth', 'عمق خط لوله');
  String get zeroCopy => _t('Zero-copy (sendfile / splice)', 'بدون کپی (sendfile / splice)');
  String get wmm => _t('Wi-Fi priority (WMM)', 'اولویت وای‌فای (WMM)');
  String get wmmBe => _t('Normal', 'عادی');
  String get wmmVi => _t('Video', 'ویدیو');
  String get wmmVo => _t('Voice', 'صدا');
  String get heicSection => _t('HEIC photos', 'عکس‌های HEIC');
  String get heicAsk => _t('Ask me', 'بپرس');
  String get heicAlways => _t('Convert', 'تبدیل کن');
  String get heicNever => _t('Keep', 'نگه دار');
  String get jpegQuality => _t('JPEG quality', 'کیفیت JPEG');
  String get saveTo => _t('Save received files to', 'فایل‌های دریافتی کجا ذخیره بشن');
  String get saveDefault => _t('Gallery, Music and Downloads', 'گالری، آهنگ‌ها و دانلودها');
  String get change => _t('Change', 'تغییر');
  String get reset => _t('Reset', 'پیش‌فرض');
  String get appearance => _t('Look & language', 'ظاهر و زبان');
  String get theme => _t('Theme', 'تم');
  String get themeSystem => _t('System', 'مثل گوشی');
  String get themeLight => _t('Light', 'روشن');
  String get themeDark => _t('Dark', 'تیره');
  String get language => _t('Language', 'زبان');
  String get thisPhone => _t('This phone', 'این گوشی');

  // ---------------------------------------------------------------- benchmark
  String get benchTitle => _t('How strong is this phone?', 'این گوشی چقدر قویه؟');
  String get benchBody => _t(
        'A quick test of everything a transfer needs: encryption, compression, memory and the network stack, on one core and on all of them.',
        'یه تست سریع از هرچی که انتقال لازم داره: رمزنگاری، فشرده‌سازی، حافظه و شبکه، هم رو یه هسته هم رو همه‌شون.',
      );
  String get benchStart => _t('Run the test', 'شروع تست');
  String get benchAgain => _t('Run it again', 'دوباره تست کن');
  String get benchRunning => _t('Giving it a little workout…', 'داره یه کم ورزش می‌کنه…');
  String get benchRunningSub => _t('Takes about 5 seconds', 'حدود ۵ ثانیه طول می‌کشه');
  String get score => _t('Score', 'امتیاز');
  String get singleCore => _t('Single core', 'تک‌هسته');
  String get multiCore => _t('All cores', 'همه‌ی هسته‌ها');
  String get benchEncrypt => _t('Encryption', 'رمزنگاری');
  String get benchCompress => _t('LZ4 compress', 'فشرده‌سازی LZ4');
  String get benchDecompress => _t('LZ4 decompress', 'بازکردن LZ4');
  String get benchMemory => _t('Memory copy', 'کپی حافظه');
  String get benchNet => _t('Network stack', 'پشته‌ی شبکه');
  String get higherBetter => _t('Higher is better, there\'s no ceiling.', 'هرچی بالاتر بهتر، سقفی هم نداره.');
  String verdict(double mbps) {
    final tier = mbps >= 600
        ? _t('Wi-Fi 7', 'وای‌فای ۷')
        : mbps >= 250
            ? _t('Wi-Fi 6E / 6', 'وای‌فای ۶E / ۶')
            : mbps >= 100
                ? _t('Wi-Fi 5', 'وای‌فای ۵')
                : _t('Wi-Fi 4', 'وای‌فای ۴');
    final v = n(mbps.round());
    return _t(
      'Even with encryption and compression on, this phone can push about $v MB/s. That\'s enough to keep $tier busy. 💪',
      'حتی با رمزنگاری و فشرده‌سازی روشن، این گوشی حدود $v مگابایت بر ثانیه جابه‌جا می‌کنه. یعنی از پس $tier برمیاد. 💪',
    );
  }
}

extension SContext on BuildContext {
  S get s => S.of(this);
}
