import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// 6 OKLCH-calibrated accent presets (Default = Ocean-Slate Blue `teal`).
enum GrassBagAccent {
  teal('海湾蓝', Color(0xFF236185), Color(0xFF4DA6E8)),
  mist('雾蓝', Color(0xFF4B67B4), Color(0xFF7B8DF5)),
  moss('苔青', Color(0xFF34766F), Color(0xFF48C78E)),
  dusk('暮紫', Color(0xFF726291), Color(0xFFB48EF2)),
  amber('琥珀', Color(0xFF8D6636), Color(0xFFF0AE46)),
  graphite('石墨', Color(0xFF2C2E32), Color(0xFFA8B0BE));

  const GrassBagAccent(this.label, this.swatch, this.swatchDark);
  final String label;
  final Color swatch;
  final Color swatchDark;

  Color swatchFor(bool isDark) => isDark ? swatchDark : swatch;
}

/// 3 performance/visual glass tiers mapped onto `liquid_glass_widgets`.
enum GrassBagGlassTier {
  liquid('液态'),
  frosted('磨砂'),
  solid('纯色');

  const GrassBagGlassTier(this.label);
  final String label;
}

/// Complete light + dsh-Go Deep-Slate dark (L = 0.23–0.25) token ladder.
@immutable
class GrassBagTokens extends ThemeExtension<GrassBagTokens> {
  const GrassBagTokens({
    required this.isDark,
    required this.accent,
    required this.bgTop,
    required this.bgBottom,
    required this.glowTopRight,
    required this.glowBottomLeft,
    required this.bgSolid,
    required this.bgGrouped,
    required this.sidebarDocked,
    required this.sidebarDrawerTop,
    required this.sidebarDrawerBottom,
    required this.card,
    required this.cardSolid,
    required this.fill1,
    required this.fill2,
    required this.sep,
    required this.sepStrong,
    required this.text,
    required this.text2,
    required this.text3,
    required this.primary,
    required this.primaryHi,
    required this.onPrimary,
    required this.primarySoft,
    required this.userBubble,
    required this.ok,
    required this.okSoft,
    required this.warn,
    required this.warnSoft,
    required this.err,
    required this.errSoft,
    required this.dusk,
    required this.duskSoft,
    required this.codeBg,
    required this.codeBar,
    required this.codeFg,
    required this.feather,
    required this.glassTint,
    required this.sheetTop,
    required this.sheetBottom,
  });

  final bool isDark;
  final GrassBagAccent accent;
  final Color bgTop;
  final Color bgBottom;
  final Color glowTopRight;
  final Color glowBottomLeft;
  final Color bgSolid;
  final Color bgGrouped;
  final Color sidebarDocked;
  final Color sidebarDrawerTop;
  final Color sidebarDrawerBottom;
  final Color card;
  final Color cardSolid;
  final Color fill1;
  final Color fill2;
  final Color sep;
  final Color sepStrong;
  final Color text;
  final Color text2;
  final Color text3;
  final Color primary;
  final Color primaryHi;
  final Color onPrimary;
  final Color primarySoft;
  final Color userBubble;
  final Color ok;
  final Color okSoft;
  final Color warn;
  final Color warnSoft;
  final Color err;
  final Color errSoft;
  final Color dusk;
  final Color duskSoft;
  final Color codeBg;
  final Color codeBar;
  final Color codeFg;
  final Color feather;
  final Color glassTint;
  final Color sheetTop;
  final Color sheetBottom;

  static GrassBagTokens of(BuildContext context) {
    return Theme.of(context).extension<GrassBagTokens>() ??
        GrassBagTokens.resolve(GrassBagAccent.teal, Brightness.light);
  }

  static GrassBagTokens resolve(GrassBagAccent accent, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    if (!dark) {
      return switch (accent) {
        GrassBagAccent.teal => const GrassBagTokens(
            isDark: false,
            accent: GrassBagAccent.teal,
            bgTop: Color(0xFFEAF3FC),
            bgBottom: Color(0xFFE7EFFA),
            glowTopRight: Color(0x7890C5EC),
            glowBottomLeft: Color(0x66B9C9EC),
            bgSolid: Color(0xFFF2F6FC),
            bgGrouped: Color(0xFFEBF2F9),
            sidebarDocked: Color(0xC4ECF4FA),
            sidebarDrawerTop: Color(0xF5F6FAFE),
            sidebarDrawerBottom: Color(0xF7EDF4FA),
            card: Color(0xC8FFFFFF),
            cardSolid: Color(0xFFFFFFFF),
            fill1: Color(0x0E162E42),
            fill2: Color(0x1A162E42),
            sep: Color(0x16162E42),
            sepStrong: Color(0x28162E42),
            text: Color(0xFF0F1D29),
            text2: Color(0xFF3A4F61),
            text3: Color(0xFF52687A),
            primary: Color(0xFF1F5F87),
            primaryHi: Color(0xFF3B8BC0),
            onPrimary: Color(0xFFFFFFFF),
            primarySoft: Color(0x201F5F87),
            userBubble: Color(0xFFD6E9F8),
            ok: Color(0xFF117A4B),
            okSoft: Color(0x1F117A4B),
            warn: Color(0xFF9A5508),
            warnSoft: Color(0x24C47612),
            err: Color(0xFFB3423E),
            errSoft: Color(0x1FB3423E),
            dusk: Color(0xFF6B5B8E),
            duskSoft: Color(0x216B5B8E),
            codeBg: Color(0xFF131920),
            codeBar: Color(0xFF1A222B),
            codeFg: Color(0xFFE4EEF5),
            feather: Color(0xFFEEF5FA),
            glassTint: Color(0xB8FFFFFF),
            sheetTop: Color(0xF0F7FBFE),
            sheetBottom: Color(0xF7EFF5FA),
          ),
        GrassBagAccent.mist => const GrassBagTokens(
            isDark: false,
            accent: GrassBagAccent.mist,
            bgTop: Color(0xFFEBF1FE),
            bgBottom: Color(0xFFF6F7FC),
            glowTopRight: Color(0x5CABC3FC),
            glowBottomLeft: Color(0x57D5CBEB),
            bgSolid: Color(0xFFEEF2FC),
            bgGrouped: Color(0xFFEEF1F9),
            sidebarDocked: Color(0xBDECF0FB),
            sidebarDrawerTop: Color(0xF2F5F7FE),
            sidebarDrawerBottom: Color(0xF7EEF1FA),
            card: Color(0xB8FFFFFF),
            cardSolid: Color(0xFFFFFFFF),
            fill1: Color(0x0D1A2340),
            fill2: Color(0x181A2340),
            sep: Color(0x151A2340),
            sepStrong: Color(0x251A2340),
            text: Color(0xFF1B2233),
            text2: Color(0xFF4C556B),
            text3: Color(0xFF5B657B),
            primary: Color(0xFF4B67B4),
            primaryHi: Color(0xFF6A86D4),
            onPrimary: Color(0xFFFFFFFF),
            primarySoft: Color(0x204B67B4),
            userBubble: Color(0xFFD9E4FD),
            ok: Color(0xFF117A4B),
            okSoft: Color(0x1F117A4B),
            warn: Color(0xFF9A5508),
            warnSoft: Color(0x24C47612),
            err: Color(0xFFA54743),
            errSoft: Color(0x1FA54743),
            dusk: Color(0xFF726291),
            duskSoft: Color(0x21726291),
            codeBg: Color(0xFF14171E),
            codeBar: Color(0xFF1C2029),
            codeFg: Color(0xFFE6E9F0),
            feather: Color(0xFFEEF2FC),
            glassTint: Color(0xB8FFFFFF),
            sheetTop: Color(0xEDF7F9FE),
            sheetBottom: Color(0xF7EEF2FA),
          ),
        GrassBagAccent.moss => const GrassBagTokens(
            isDark: false,
            accent: GrassBagAccent.moss,
            bgTop: Color(0xFFEBF4F2),
            bgBottom: Color(0xFFF5F8F7),
            glowTopRight: Color(0x57A3CEC8),
            glowBottomLeft: Color(0x4DB9D7E3),
            bgSolid: Color(0xFFF1F6F5),
            bgGrouped: Color(0xFFEEF3F2),
            sidebarDocked: Color(0xBDECF4F2),
            sidebarDrawerTop: Color(0xF2F4FAF9),
            sidebarDrawerBottom: Color(0xF7EEF5F4),
            card: Color(0xB8FFFFFF),
            cardSolid: Color(0xFFFFFFFF),
            fill1: Color(0x0D122A27),
            fill2: Color(0x18122A27),
            sep: Color(0x15122A27),
            sepStrong: Color(0x25122A27),
            text: Color(0xFF1C2726),
            text2: Color(0xFF4C5C5A),
            text3: Color(0xFF546361),
            primary: Color(0xFF34766F),
            primaryHi: Color(0xFF4B968E),
            onPrimary: Color(0xFFFFFFFF),
            primarySoft: Color(0x2034766F),
            userBubble: Color(0xFFD6E8E6),
            ok: Color(0xFF117A4B),
            okSoft: Color(0x1F117A4B),
            warn: Color(0xFF9A5508),
            warnSoft: Color(0x24C47612),
            err: Color(0xFFA54743),
            errSoft: Color(0x1FA54743),
            dusk: Color(0xFF726291),
            duskSoft: Color(0x21726291),
            codeBg: Color(0xFF14191A),
            codeBar: Color(0xFF1C2324),
            codeFg: Color(0xFFE2ECEA),
            feather: Color(0xFFEFF6F4),
            glassTint: Color(0xB8FFFFFF),
            sheetTop: Color(0xEDF9FCFB),
            sheetBottom: Color(0xF7F1F6F5),
          ),
        GrassBagAccent.dusk => const GrassBagTokens(
            isDark: false,
            accent: GrassBagAccent.dusk,
            bgTop: Color(0xFFF2EFF9),
            bgBottom: Color(0xFFF7F5FA),
            glowTopRight: Color(0x5CC8BDE1),
            glowBottomLeft: Color(0x4DE6C7D7),
            bgSolid: Color(0xFFF3F1F7),
            bgGrouped: Color(0xFFF1EEF6),
            sidebarDocked: Color(0xBDF1EDF8),
            sidebarDrawerTop: Color(0xF2F8F5FD),
            sidebarDrawerBottom: Color(0xF7F1EDF7),
            card: Color(0xB8FFFFFF),
            cardSolid: Color(0xFFFFFFFF),
            fill1: Color(0x0D231C30),
            fill2: Color(0x18231C30),
            sep: Color(0x15231C30),
            sepStrong: Color(0x25231C30),
            text: Color(0xFF211C2B),
            text2: Color(0xFF534B61),
            text3: Color(0xFF615A70),
            primary: Color(0xFF726291),
            primaryHi: Color(0xFF907FB0),
            onPrimary: Color(0xFFFFFFFF),
            primarySoft: Color(0x20726291),
            userBubble: Color(0xFFE6E1F1),
            ok: Color(0xFF117A4B),
            okSoft: Color(0x1F117A4B),
            warn: Color(0xFF9A5508),
            warnSoft: Color(0x24C47612),
            err: Color(0xFFA54743),
            errSoft: Color(0x1FA54743),
            dusk: Color(0xFF726291),
            duskSoft: Color(0x21726291),
            codeBg: Color(0xFF17151D),
            codeBar: Color(0xFF211E29),
            codeFg: Color(0xFFEAE7F0),
            feather: Color(0xFFF3F1F7),
            glassTint: Color(0xB8FFFFFF),
            sheetTop: Color(0xEDF9F7FC),
            sheetBottom: Color(0xF7F2EFF8),
          ),
        GrassBagAccent.amber => const GrassBagTokens(
            isDark: false,
            accent: GrassBagAccent.amber,
            bgTop: Color(0xFFF7F2EA),
            bgBottom: Color(0xFFF9F6F1),
            glowTopRight: Color(0x57DCBE9D),
            glowBottomLeft: Color(0x4DEAC8C1),
            bgSolid: Color(0xFFF6F3EE),
            bgGrouped: Color(0xFFF4F0EA),
            sidebarDocked: Color(0xBDF4EFE8),
            sidebarDrawerTop: Color(0xF2FAF7F2),
            sidebarDrawerBottom: Color(0xF7F4EFE8),
            card: Color(0xB8FFFFFF),
            cardSolid: Color(0xFFFFFFFF),
            fill1: Color(0x0D2E2214),
            fill2: Color(0x182E2214),
            sep: Color(0x152E2214),
            sepStrong: Color(0x252E2214),
            text: Color(0xFF292118),
            text2: Color(0xFF5D5245),
            text3: Color(0xFF6A5F52),
            primary: Color(0xFF8D6636),
            primaryHi: Color(0xFFAD814A),
            onPrimary: Color(0xFFFFFFFF),
            primarySoft: Color(0x208D6636),
            userBubble: Color(0xFFEEE2D3),
            ok: Color(0xFF117A4B),
            okSoft: Color(0x1F117A4B),
            warn: Color(0xFF9A5508),
            warnSoft: Color(0x24C47612),
            err: Color(0xFFA54743),
            errSoft: Color(0x1FA54743),
            dusk: Color(0xFF726291),
            duskSoft: Color(0x21726291),
            codeBg: Color(0xFF181613),
            codeBar: Color(0xFF221F1B),
            codeFg: Color(0xFFEEEAE4),
            feather: Color(0xFFF6F3EE),
            glassTint: Color(0xB8FFFFFF),
            sheetTop: Color(0xEDFAF7F3),
            sheetBottom: Color(0xF7F4EFE9),
          ),
        GrassBagAccent.graphite => const GrassBagTokens(
            isDark: false,
            accent: GrassBagAccent.graphite,
            bgTop: Color(0xFFEFF1F5),
            bgBottom: Color(0xFFF6F7F9),
            glowTopRight: Color(0x24B8BEC8),
            glowBottomLeft: Color(0x1EC8CDD6),
            bgSolid: Color(0xFFF2F3F5),
            bgGrouped: Color(0xFFF0F1F3),
            sidebarDocked: Color(0xC2EEF0F3),
            sidebarDrawerTop: Color(0xF2F6F7F9),
            sidebarDrawerBottom: Color(0xF7EEF0F3),
            card: Color(0xB8FFFFFF),
            cardSolid: Color(0xFFFFFFFF),
            fill1: Color(0x0D191B1E),
            fill2: Color(0x18191B1E),
            sep: Color(0x15191B1E),
            sepStrong: Color(0x25191B1E),
            text: Color(0xFF191B1E),
            text2: Color(0xFF4F535B),
            text3: Color(0xFF5D626D),
            primary: Color(0xFF2C2E32),
            primaryHi: Color(0xFF4B4F56),
            onPrimary: Color(0xFFFFFFFF),
            primarySoft: Color(0x182C2E32),
            userBubble: Color(0xFFE0E3E8),
            ok: Color(0xFF117A4B),
            okSoft: Color(0x1F117A4B),
            warn: Color(0xFF9A5508),
            warnSoft: Color(0x24C47612),
            err: Color(0xFFA54743),
            errSoft: Color(0x1FA54743),
            dusk: Color(0xFF726291),
            duskSoft: Color(0x21726291),
            codeBg: Color(0xFF151619),
            codeBar: Color(0xFF1E2024),
            codeFg: Color(0xFFE8EAEE),
            feather: Color(0xFFF2F3F5),
            glassTint: Color(0xB8FFFFFF),
            sheetTop: Color(0xEDF7F8FA),
            sheetBottom: Color(0xF7EFF1F4),
          ),
      };
    }

    // LUMINOUS MIDNIGHT-SLATE DARK MODE:
    // - Rich midnight-slate canvas (#1F2838 -> #181F2D -> #111622; luminance ~0.014, zero pitch-black glare)
    //   gives spherical obsidian Liquid Glass (16%–34% tint + specular rim) unmistakable optical depth
    //   and crystal edge refraction while remaining effortless for long reading sessions.
    return switch (accent) {
      GrassBagAccent.teal => const GrassBagTokens(
          isDark: true,
          accent: GrassBagAccent.teal,
          bgTop: Color(0xFF1F2838),
          bgBottom: Color(0xFF111622),
          glowTopRight: Color(0x4C4DA6E8),
          glowBottomLeft: Color(0x406B7FE3),
          bgSolid: Color(0xFF192130),
          bgGrouped: Color(0xFF161D2A),
          sidebarDocked: Color(0xEC131823),
          sidebarDrawerTop: Color(0xF51E2636),
          sidebarDrawerBottom: Color(0xF8171E2B),
          card: Color(0xBA222A3A),
          cardSolid: Color(0xFF222A3A),
          fill1: Color(0x16FFFFFF),
          fill2: Color(0x24FFFFFF),
          sep: Color(0x18FFFFFF),
          sepStrong: Color(0x28FFFFFF),
          text: Color(0xFFEFF2F7),
          text2: Color(0xFFB4BECE),
          text3: Color(0xFF9BA8BC),
          primary: Color(0xFF4DA6E8),
          primaryHi: Color(0xFF78C0F5),
          onPrimary: Color(0xFF0A1622),
          primarySoft: Color(0x264DA6E8),
          userBubble: Color(0xFF2E384A),
          ok: Color(0xFF46C98C),
          okSoft: Color(0x2646C98C),
          warn: Color(0xFFF0B24C),
          warnSoft: Color(0x26F0B24C),
          err: Color(0xFFFF8582),
          errSoft: Color(0x26FF8582),
          dusk: Color(0xFFB48EF2),
          duskSoft: Color(0x26B48EF2),
          codeBg: Color(0xFF141820),
          codeBar: Color(0xFF1B202B),
          codeFg: Color(0xFFE6ECF5),
          feather: Color(0xFF1D222C),
          glassTint: Color(0xAD272D3A),
          sheetTop: Color(0xF5282F3C),
          sheetBottom: Color(0xF8212732),
        ),
      GrassBagAccent.mist => const GrassBagTokens(
          isDark: true,
          accent: GrassBagAccent.mist,
          bgTop: Color(0xFF1F2538),
          bgBottom: Color(0xFF111523),
          glowTopRight: Color(0x4C7B8DF5),
          glowBottomLeft: Color(0x404DA6E8),
          bgSolid: Color(0xFF1A2031),
          bgGrouped: Color(0xFF161C2B),
          sidebarDocked: Color(0xEC131724),
          sidebarDrawerTop: Color(0xF51E2437),
          sidebarDrawerBottom: Color(0xF8171C2C),
          card: Color(0xBA22283B),
          cardSolid: Color(0xFF22283B),
          fill1: Color(0x16FFFFFF),
          fill2: Color(0x24FFFFFF),
          sep: Color(0x18FFFFFF),
          sepStrong: Color(0x28FFFFFF),
          text: Color(0xFFEFF2F8),
          text2: Color(0xFFB4BCD0),
          text3: Color(0xFF9BA5BE),
          primary: Color(0xFF7B8DF5),
          primaryHi: Color(0xFF9AA8FA),
          onPrimary: Color(0xFF0D1124),
          primarySoft: Color(0x267B8DF5),
          userBubble: Color(0xFF2F354B),
          ok: Color(0xFF46C98C),
          okSoft: Color(0x2646C98C),
          warn: Color(0xFFF0B24C),
          warnSoft: Color(0x26F0B24C),
          err: Color(0xFFFF8582),
          errSoft: Color(0x26FF8582),
          dusk: Color(0xFFB48EF2),
          duskSoft: Color(0x26B48EF2),
          codeBg: Color(0xFF141722),
          codeBar: Color(0xFF1B1F2D),
          codeFg: Color(0xFFE6EAF5),
          feather: Color(0xFF1D212E),
          glassTint: Color(0xAD272C3B),
          sheetTop: Color(0xF5282E3E),
          sheetBottom: Color(0xF8212634),
        ),
      GrassBagAccent.moss => const GrassBagTokens(
          isDark: true,
          accent: GrassBagAccent.moss,
          bgTop: Color(0xFF1D2928),
          bgBottom: Color(0xFF101918),
          glowTopRight: Color(0x4848C78E),
          glowBottomLeft: Color(0x3C4DA6B8),
          bgSolid: Color(0xFF182322),
          bgGrouped: Color(0xFF151F1E),
          sidebarDocked: Color(0xEC121918),
          sidebarDrawerTop: Color(0xF51C2726),
          sidebarDrawerBottom: Color(0xF8161F1E),
          card: Color(0xBA202C2B),
          cardSolid: Color(0xFF202C2B),
          fill1: Color(0x16FFFFFF),
          fill2: Color(0x24FFFFFF),
          sep: Color(0x18FFFFFF),
          sepStrong: Color(0x28FFFFFF),
          text: Color(0xFFEEF3F2),
          text2: Color(0xFFB2C0BE),
          text3: Color(0xFF98ACA8),
          primary: Color(0xFF48C78E),
          primaryHi: Color(0xFF6EDBA8),
          onPrimary: Color(0xFF0E2219),
          primarySoft: Color(0x2648C78E),
          userBubble: Color(0xFF293A37),
          ok: Color(0xFF48C78E),
          okSoft: Color(0x2648C78E),
          warn: Color(0xFFF0B24C),
          warnSoft: Color(0x26F0B24C),
          err: Color(0xFFFF8582),
          errSoft: Color(0x26FF8582),
          dusk: Color(0xFFB48EF2),
          duskSoft: Color(0x26B48EF2),
          codeBg: Color(0xFF131918),
          codeBar: Color(0xFF1A2221),
          codeFg: Color(0xFFE4EFED),
          feather: Color(0xFF1C2322),
          glassTint: Color(0xAD252E2D),
          sheetTop: Color(0xF527302F),
          sheetBottom: Color(0xF8202827),
        ),
      GrassBagAccent.dusk => const GrassBagTokens(
          isDark: true,
          accent: GrassBagAccent.dusk,
          bgTop: Color(0xFF242033),
          bgBottom: Color(0xFF151221),
          glowTopRight: Color(0x48B48EF2),
          glowBottomLeft: Color(0x3CE07A9A),
          bgSolid: Color(0xFF1F1D2E),
          bgGrouped: Color(0xFF1B1928),
          sidebarDocked: Color(0xEC161321),
          sidebarDrawerTop: Color(0xF5231F32),
          sidebarDrawerBottom: Color(0xF81B1828),
          card: Color(0xBA272337),
          cardSolid: Color(0xFF272337),
          fill1: Color(0x16FFFFFF),
          fill2: Color(0x24FFFFFF),
          sep: Color(0x18FFFFFF),
          sepStrong: Color(0x28FFFFFF),
          text: Color(0xFFF1EFF7),
          text2: Color(0xFFBDB6CD),
          text3: Color(0xFFA49DB8),
          primary: Color(0xFFB48EF2),
          primaryHi: Color(0xFFCAAAF8),
          onPrimary: Color(0xFF1B1329),
          primarySoft: Color(0x26B48EF2),
          userBubble: Color(0xFF352F47),
          ok: Color(0xFF46C98C),
          okSoft: Color(0x2646C98C),
          warn: Color(0xFFF0B24C),
          warnSoft: Color(0x26F0B24C),
          err: Color(0xFFFF8582),
          errSoft: Color(0x26FF8582),
          dusk: Color(0xFFB48EF2),
          duskSoft: Color(0x26B48EF2),
          codeBg: Color(0xFF16141E),
          codeBar: Color(0xFF1E1B28),
          codeFg: Color(0xFFECE8F5),
          feather: Color(0xFF201E29),
          glassTint: Color(0xAD2A2736),
          sheetTop: Color(0xF52C2938),
          sheetBottom: Color(0xF824212F),
        ),
      GrassBagAccent.amber => const GrassBagTokens(
          isDark: true,
          accent: GrassBagAccent.amber,
          bgTop: Color(0xFF26221D),
          bgBottom: Color(0xFF171410),
          glowTopRight: Color(0x45F0AE46),
          glowBottomLeft: Color(0x3AD97B66),
          bgSolid: Color(0xFF211E1A),
          bgGrouped: Color(0xFF1C1915),
          sidebarDocked: Color(0xEC181512),
          sidebarDrawerTop: Color(0xF525211C),
          sidebarDrawerBottom: Color(0xF81D1A16),
          card: Color(0xBA2A2620),
          cardSolid: Color(0xFF2A2620),
          fill1: Color(0x16FFFFFF),
          fill2: Color(0x24FFFFFF),
          sep: Color(0x18FFFFFF),
          sepStrong: Color(0x28FFFFFF),
          text: Color(0xFFF4F1EC),
          text2: Color(0xFFC4BDB2),
          text3: Color(0xFFAAA296),
          primary: Color(0xFFF0AE46),
          primaryHi: Color(0xFFF7C572),
          onPrimary: Color(0xFF241805),
          primarySoft: Color(0x26F0AE46),
          userBubble: Color(0xFF383228),
          ok: Color(0xFF46C98C),
          okSoft: Color(0x2646C98C),
          warn: Color(0xFFF0AE46),
          warnSoft: Color(0x26F0AE46),
          err: Color(0xFFFF8582),
          errSoft: Color(0x26FF8582),
          dusk: Color(0xFFB48EF2),
          duskSoft: Color(0x26B48EF2),
          codeBg: Color(0xFF171613),
          codeBar: Color(0xFF201E1A),
          codeFg: Color(0xFFF0ECE6),
          feather: Color(0xFF22201C),
          glassTint: Color(0xAD2C2924),
          sheetTop: Color(0xF52E2B26),
          sheetBottom: Color(0xF826231F),
        ),
      GrassBagAccent.graphite => const GrassBagTokens(
          isDark: true,
          accent: GrassBagAccent.graphite,
          bgTop: Color(0xFF23252C),
          bgBottom: Color(0xFF15161C),
          glowTopRight: Color(0x3EA8B0BE),
          glowBottomLeft: Color(0x327A8291),
          bgSolid: Color(0xFF1E2027),
          bgGrouped: Color(0xFF191B21),
          sidebarDocked: Color(0xEC16171C),
          sidebarDrawerTop: Color(0xF522242B),
          sidebarDrawerBottom: Color(0xF81A1C22),
          card: Color(0xBA262931),
          cardSolid: Color(0xFF262931),
          fill1: Color(0x16FFFFFF),
          fill2: Color(0x24FFFFFF),
          sep: Color(0x18FFFFFF),
          sepStrong: Color(0x28FFFFFF),
          text: Color(0xFFF1F2F5),
          text2: Color(0xFFB9BDC7),
          text3: Color(0xFF9FA4B2),
          primary: Color(0xFFD8DCE6),
          primaryHi: Color(0xFFFFFFFF),
          onPrimary: Color(0xFF18191D),
          primarySoft: Color(0x24D8DCE6),
          userBubble: Color(0xFF32353E),
          ok: Color(0xFF46C98C),
          okSoft: Color(0x2646C98C),
          warn: Color(0xFFF0B24C),
          warnSoft: Color(0x26F0B24C),
          err: Color(0xFFFF8582),
          errSoft: Color(0x26FF8582),
          dusk: Color(0xFFB48EF2),
          duskSoft: Color(0x26B48EF2),
          codeBg: Color(0xFF16171B),
          codeBar: Color(0xFF1E2025),
          codeFg: Color(0xFFECEEF2),
          feather: Color(0xFF202126),
          glassTint: Color(0xAD2A2C33),
          sheetTop: Color(0xF52C2E36),
          sheetBottom: Color(0xF824262C),
        ),
    };
  }

  ThemeData toMaterialTheme() {
    final brightness = isDark ? Brightness.dark : Brightness.light;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: onPrimary,
      secondary: primary,
      onSecondary: onPrimary,
      error: err,
      onError: Colors.white,
      surface: bgSolid,
      onSurface: text,
      surfaceContainerHighest: cardSolid,
      onSurfaceVariant: text2,
      outline: sepStrong,
      outlineVariant: sep,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      cupertinoOverrideTheme: CupertinoThemeData(
        brightness: brightness,
        primaryColor: primary,
        scaffoldBackgroundColor: bgSolid,
        textTheme: CupertinoTextThemeData(
          primaryColor: primary,
          textStyle: TextStyle(color: text),
        ),
      ),
      scaffoldBackgroundColor: bgSolid,
      dividerColor: sep,
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: fill1,
        circularTrackColor: fill1,
        linearMinHeight: 5,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: primary,
        inactiveTrackColor: fill2,
        thumbColor: Colors.white,
        overlayColor: primarySoft,
        trackHeight: 4,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(4),
        radius: const Radius.circular(999),
        thumbColor: WidgetStatePropertyAll(
          isDark ? Colors.white.withValues(alpha: 0.24) : Colors.black.withValues(alpha: 0.20),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardSolid,
        surfaceTintColor: Colors.transparent,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(26)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: sheetTop,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      // Eliminate harsh Material 90-degree rectangular splash/highlight boxes on tap & long-press.
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      focusColor: Colors.transparent,
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 650),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        textStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: text,
        ),
        decoration: BoxDecoration(
          color: sheetTop.withValues(alpha: isDark ? 0.94 : 0.96),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: sepStrong,
            width: 0.7,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.34 : 0.10),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      textTheme: ThemeData(brightness: brightness).textTheme.apply(
            bodyColor: text,
            displayColor: text,
          ),
      extensions: [this],
    );
  }

  @override
  GrassBagTokens copyWith({GrassBagAccent? accent, bool? isDark}) {
    return GrassBagTokens.resolve(
      accent ?? this.accent,
      (isDark ?? this.isDark) ? Brightness.dark : Brightness.light,
    );
  }

  @override
  GrassBagTokens lerp(covariant ThemeExtension<GrassBagTokens>? other, double t) {
    if (other is! GrassBagTokens) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t) ?? (t < 0.5 ? a : b);
    return GrassBagTokens(
      isDark: t < 0.5 ? isDark : other.isDark,
      accent: t < 0.5 ? accent : other.accent,
      bgTop: c(bgTop, other.bgTop),
      bgBottom: c(bgBottom, other.bgBottom),
      glowTopRight: c(glowTopRight, other.glowTopRight),
      glowBottomLeft: c(glowBottomLeft, other.glowBottomLeft),
      bgSolid: c(bgSolid, other.bgSolid),
      bgGrouped: c(bgGrouped, other.bgGrouped),
      sidebarDocked: c(sidebarDocked, other.sidebarDocked),
      sidebarDrawerTop: c(sidebarDrawerTop, other.sidebarDrawerTop),
      sidebarDrawerBottom: c(sidebarDrawerBottom, other.sidebarDrawerBottom),
      card: c(card, other.card),
      cardSolid: c(cardSolid, other.cardSolid),
      fill1: c(fill1, other.fill1),
      fill2: c(fill2, other.fill2),
      sep: c(sep, other.sep),
      sepStrong: c(sepStrong, other.sepStrong),
      text: c(text, other.text),
      text2: c(text2, other.text2),
      text3: c(text3, other.text3),
      primary: c(primary, other.primary),
      primaryHi: c(primaryHi, other.primaryHi),
      onPrimary: c(onPrimary, other.onPrimary),
      primarySoft: c(primarySoft, other.primarySoft),
      userBubble: c(userBubble, other.userBubble),
      ok: c(ok, other.ok),
      okSoft: c(okSoft, other.okSoft),
      warn: c(warn, other.warn),
      warnSoft: c(warnSoft, other.warnSoft),
      err: c(err, other.err),
      errSoft: c(errSoft, other.errSoft),
      dusk: c(dusk, other.dusk),
      duskSoft: c(duskSoft, other.duskSoft),
      codeBg: c(codeBg, other.codeBg),
      codeBar: c(codeBar, other.codeBar),
      codeFg: c(codeFg, other.codeFg),
      feather: c(feather, other.feather),
      glassTint: c(glassTint, other.glassTint),
      sheetTop: c(sheetTop, other.sheetTop),
      sheetBottom: c(sheetBottom, other.sheetBottom),
    );
  }
}

/// Single-pass GPU-efficient atmospheric canvas (`RepaintBoundary` + 1 `CustomPaint`)
/// replacing 6 stacked full-screen `DecoratedBox` layers (cuts GPU fill-rate by ~80%!)
/// while providing clean silk-wave depth that visibly refracts behind Liquid Glass!
class GrassBagCanvasBackground extends StatelessWidget {
  const GrassBagCanvasBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final t = GrassBagTokens.of(context);
    return RepaintBoundary(
      child: CustomPaint(
        isComplex: true,
        willChange: false,
        painter: _AtmosphericSilkPainter(
          isDark: t.isDark,
          bgTop: t.bgTop,
          bgSolid: t.bgSolid,
          bgBottom: t.bgBottom,
          glowTopRight: t.glowTopRight,
          glowBottomLeft: t.glowBottomLeft,
          primary: t.primary,
          primaryHi: t.primaryHi,
          dusk: t.dusk,
        ),
      ),
    );
  }
}

class _AtmosphericSilkPainter extends CustomPainter {
  const _AtmosphericSilkPainter({
    required this.isDark,
    required this.bgTop,
    required this.bgSolid,
    required this.bgBottom,
    required this.glowTopRight,
    required this.glowBottomLeft,
    required this.primary,
    required this.primaryHi,
    required this.dusk,
  });

  final bool isDark;
  final Color bgTop;
  final Color bgSolid;
  final Color bgBottom;
  final Color glowTopRight;
  final Color glowBottomLeft;
  final Color primary;
  final Color primaryHi;
  final Color dusk;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;

    // 1. Clean 3-stop vertical tonal gradient (anchored cleanly to `bgTop` at y=0 so
    // the status-bar cap blends seamlessly with zero horizontal seam!)
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [bgTop, bgSolid, bgBottom],
          stops: const [0.0, 0.52, 1.0],
        ).createShader(rect),
    );

    // 2. Sculpted aurora depth — softer atmospheric lift behind header & composer zones
    final topOrbCenter = Offset(w * 0.82, h * 0.14);
    final topOrbRadius = (w > h ? w : h) * 0.48;
    canvas.drawCircle(
      topOrbCenter,
      topOrbRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            glowTopRight.withValues(alpha: isDark ? 0.34 : 0.56),
            primaryHi.withValues(alpha: isDark ? 0.13 : 0.22),
            Colors.transparent,
          ],
          stops: const [0.0, 0.42, 1.0],
        ).createShader(Rect.fromCircle(center: topOrbCenter, radius: topOrbRadius)),
    );

    final botOrbCenter = Offset(w * 0.20, h * 0.90);
    final botOrbRadius = (w > h ? w : h) * 0.46;
    canvas.drawCircle(
      botOrbCenter,
      botOrbRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            glowBottomLeft.withValues(alpha: isDark ? 0.28 : 0.48),
            dusk.withValues(alpha: isDark ? 0.11 : 0.18),
            Colors.transparent,
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromCircle(center: botOrbCenter, radius: botOrbRadius)),
    );

    // 3. Mid-frequency diagonal caustic silk bands behind the floating top pills & bottom composer
    // so curved Liquid Glass lenses catch smooth luminous gradients even on empty screens!
    final topRibbon = Path()
      ..moveTo(-w * 0.10, h * 0.16)
      ..cubicTo(w * 0.26, h * 0.07, w * 0.64, h * 0.24, w * 1.10, h * 0.11)
      ..lineTo(w * 1.10, h * 0.27)
      ..cubicTo(w * 0.62, h * 0.38, w * 0.24, h * 0.21, -w * 0.10, h * 0.32)
      ..close();

    canvas.drawPath(
      topRibbon,
      Paint()
        ..blendMode = isDark ? BlendMode.plus : BlendMode.srcOver
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            primaryHi.withValues(alpha: isDark ? 0.09 : 0.18),
            (isDark ? Colors.white : glowTopRight).withValues(alpha: isDark ? 0.045 : 0.14),
            Colors.transparent,
          ],
          stops: const [0.0, 0.48, 1.0],
        ).createShader(Rect.fromLTWH(0, h * 0.05, w, h * 0.36)),
    );

    final bottomRibbon = Path()
      ..moveTo(-w * 0.10, h * 0.82)
      ..cubicTo(w * 0.30, h * 0.72, w * 0.68, h * 0.90, w * 1.10, h * 0.77)
      ..lineTo(w * 1.10, h * 0.96)
      ..cubicTo(w * 0.66, h * 1.04, w * 0.28, h * 0.88, -w * 0.10, h * 0.98)
      ..close();

    canvas.drawPath(
      bottomRibbon,
      Paint()
        ..blendMode = isDark ? BlendMode.plus : BlendMode.srcOver
        ..shader = LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [
            dusk.withValues(alpha: isDark ? 0.075 : 0.13),
            primaryHi.withValues(alpha: isDark ? 0.055 : 0.11),
            Colors.transparent,
          ],
          stops: const [0.0, 0.52, 1.0],
        ).createShader(Rect.fromLTWH(0, h * 0.70, w, h * 0.32)),
    );
  }

  @override
  bool shouldRepaint(covariant _AtmosphericSilkPainter old) =>
      old.isDark != isDark ||
      old.bgTop != bgTop ||
      old.bgSolid != bgSolid ||
      old.bgBottom != bgBottom ||
      old.glowTopRight != glowTopRight ||
      old.glowBottomLeft != glowBottomLeft ||
      old.primary != primary ||
      old.primaryHi != primaryHi ||
      old.dusk != dusk;
}
