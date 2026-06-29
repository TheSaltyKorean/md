import 'dart:convert';

/// Horizontal placement used for header/footer slots and the logo.
enum PrintAlign { left, center, right }

/// A reusable print/branding template that controls how a document looks when
/// printed or exported to PDF: fonts, colours, logo, header & footer content,
/// page numbering and an optional watermark (e.g. "CONFIDENTIAL").
///
/// Profiles are stored as JSON and can be associated with individual documents,
/// so a work document can carry company branding while personal notes use a
/// plain personal profile.
class PrintProfile {
  const PrintProfile({
    required this.id,
    required this.name,
    this.companyName,
    this.logoPath,
    this.logoAlign = PrintAlign.left,
    this.fontFamily = 'Roboto',
    this.primaryColor = 0xFF1A237E,
    this.textColor = 0xFF1A1A1A,
    this.headerText,
    this.footerText,
    this.showPageNumbers = true,
    this.showDate = true,
    this.showTitleInHeader = true,
    this.watermarkText,
    this.confidentialLabel,
    this.marginCm = 2.0,
    this.accentRule = true,
    this.headingRule = false,
    this.footerCentered = false,
    this.coverLogo = false,
    this.accentColor,
  });

  /// Stable identifier (also used as the per-document association key).
  final String id;

  /// Display name shown in the profile picker, e.g. "Work".
  final String name;

  /// Optional company / entity name printed in header & footer bands.
  final String? companyName;

  /// Absolute path to a logo image (PNG/JPG). Null = no logo.
  final String? logoPath;
  final PrintAlign logoAlign;

  /// Google Fonts family name used for body text (e.g. Roboto, Lato,
  /// Merriweather, Montserrat, Open Sans, Source Sans 3, Noto Serif).
  final String fontFamily;

  /// ARGB colour for headings, header band & accent rules.
  final int primaryColor;

  /// ARGB colour for body text.
  final int textColor;

  /// Optional centred header text. If null, the document title is used when
  /// [showTitleInHeader] is true.
  final String? headerText;

  /// Optional footer text, e.g. "© 2026 Your Company".
  final String? footerText;

  final bool showPageNumbers;
  final bool showDate;
  final bool showTitleInHeader;

  /// Diagonal background watermark text, e.g. "CONFIDENTIAL". Null = none.
  final String? watermarkText;

  /// Confidentiality / classification label shown in the header band,
  /// e.g. "CONFIDENTIAL", "INTERNAL USE ONLY". Null = none.
  final String? confidentialLabel;

  /// Page margin in centimetres.
  final double marginCm;

  /// Draw a thin accent rule under the header / above the footer.
  final bool accentRule;

  /// Draw a primary-colour underline rule beneath each section heading (the
  /// SK Meridian brand look).
  final bool headingRule;

  /// Use a single centred footer line "<footer> — <title> | Page N of M"
  /// (grey, hairline top) instead of the split left/right footer.
  final bool footerCentered;

  /// Place the logo once at the top of the document (cover) rather than as a
  /// running header repeated on every page.
  final bool coverLogo;

  /// ARGB colour for links / secondary accents. Null = use [primaryColor].
  final int? accentColor;

  PrintProfile copyWith({
    String? id,
    String? name,
    Object? companyName = _sentinel,
    Object? logoPath = _sentinel,
    PrintAlign? logoAlign,
    String? fontFamily,
    int? primaryColor,
    int? textColor,
    Object? headerText = _sentinel,
    Object? footerText = _sentinel,
    bool? showPageNumbers,
    bool? showDate,
    bool? showTitleInHeader,
    Object? watermarkText = _sentinel,
    Object? confidentialLabel = _sentinel,
    double? marginCm,
    bool? accentRule,
    bool? headingRule,
    bool? footerCentered,
    bool? coverLogo,
    Object? accentColor = _sentinel,
  }) {
    return PrintProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      companyName:
          companyName == _sentinel ? this.companyName : companyName as String?,
      logoPath: logoPath == _sentinel ? this.logoPath : logoPath as String?,
      logoAlign: logoAlign ?? this.logoAlign,
      fontFamily: fontFamily ?? this.fontFamily,
      primaryColor: primaryColor ?? this.primaryColor,
      textColor: textColor ?? this.textColor,
      headerText:
          headerText == _sentinel ? this.headerText : headerText as String?,
      footerText:
          footerText == _sentinel ? this.footerText : footerText as String?,
      showPageNumbers: showPageNumbers ?? this.showPageNumbers,
      showDate: showDate ?? this.showDate,
      showTitleInHeader: showTitleInHeader ?? this.showTitleInHeader,
      watermarkText: watermarkText == _sentinel
          ? this.watermarkText
          : watermarkText as String?,
      confidentialLabel: confidentialLabel == _sentinel
          ? this.confidentialLabel
          : confidentialLabel as String?,
      marginCm: marginCm ?? this.marginCm,
      accentRule: accentRule ?? this.accentRule,
      headingRule: headingRule ?? this.headingRule,
      footerCentered: footerCentered ?? this.footerCentered,
      coverLogo: coverLogo ?? this.coverLogo,
      accentColor:
          accentColor == _sentinel ? this.accentColor : accentColor as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'companyName': companyName,
        'logoPath': logoPath,
        'logoAlign': logoAlign.name,
        'fontFamily': fontFamily,
        'primaryColor': primaryColor,
        'textColor': textColor,
        'headerText': headerText,
        'footerText': footerText,
        'showPageNumbers': showPageNumbers,
        'showDate': showDate,
        'showTitleInHeader': showTitleInHeader,
        'watermarkText': watermarkText,
        'confidentialLabel': confidentialLabel,
        'marginCm': marginCm,
        'accentRule': accentRule,
        'headingRule': headingRule,
        'footerCentered': footerCentered,
        'coverLogo': coverLogo,
        'accentColor': accentColor,
      };

  factory PrintProfile.fromJson(Map<String, dynamic> json) => PrintProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        companyName: json['companyName'] as String?,
        logoPath: json['logoPath'] as String?,
        logoAlign: PrintAlign.values.firstWhere(
          (a) => a.name == json['logoAlign'],
          orElse: () => PrintAlign.left,
        ),
        fontFamily: json['fontFamily'] as String? ?? 'Roboto',
        primaryColor: json['primaryColor'] as int? ?? 0xFF1A237E,
        textColor: json['textColor'] as int? ?? 0xFF1A1A1A,
        headerText: json['headerText'] as String?,
        footerText: json['footerText'] as String?,
        showPageNumbers: json['showPageNumbers'] as bool? ?? true,
        showDate: json['showDate'] as bool? ?? true,
        showTitleInHeader: json['showTitleInHeader'] as bool? ?? true,
        watermarkText: json['watermarkText'] as String?,
        confidentialLabel: json['confidentialLabel'] as String?,
        // Clamp to the editor's slider range so an imported value stays
        // representable/adjustable in the profile editor.
        marginCm:
            ((json['marginCm'] as num?)?.toDouble() ?? 2.0).clamp(1.0, 3.5),
        accentRule: json['accentRule'] as bool? ?? true,
        headingRule: json['headingRule'] as bool? ?? false,
        footerCentered: json['footerCentered'] as bool? ?? false,
        coverLogo: json['coverLogo'] as bool? ?? false,
        accentColor: (json['accentColor'] as num?)?.toInt(),
      );

  static String encodeList(List<PrintProfile> profiles) =>
      jsonEncode(profiles.map((p) => p.toJson()).toList());

  static List<PrintProfile> decodeList(String source) {
    final raw = jsonDecode(source) as List<dynamic>;
    return raw
        .map((e) => PrintProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static const _sentinel = Object();

  // --- Built-in seed profiles -------------------------------------------------

  /// Plain personal profile: clean, no watermark, page numbers + date.
  static const PrintProfile personal = PrintProfile(
    id: 'personal',
    name: 'Personal',
    fontFamily: 'Roboto',
    primaryColor: 0xFF37474F,
    textColor: 0xFF1A1A1A,
    showPageNumbers: true,
    showDate: true,
    accentRule: false,
  );

  /// Example work profile demonstrating branding + confidentiality. Customise
  /// the company name, logo, colours and footer to suit your organisation.
  static const PrintProfile work = PrintProfile(
    id: 'work',
    name: 'Work',
    fontFamily: 'Lato',
    primaryColor: 0xFF0D3B66,
    textColor: 0xFF1B1B1B,
    footerText: 'Confidential — Internal use only',
    showPageNumbers: true,
    showDate: true,
    watermarkText: 'CONFIDENTIAL',
    confidentialLabel: 'CONFIDENTIAL',
    accentRule: true,
  );

  static List<PrintProfile> get seeds => const [personal, work];
}
