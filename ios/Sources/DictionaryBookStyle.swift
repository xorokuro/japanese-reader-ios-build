import Foundation

// Book-style presentation for purchased dictionary pages: publisher layout is kept,
// colour and type are unified. Colours come from --e-* variables that
// DictionaryPage injects from the active reader theme.
enum DictionaryBookStyle {
    static let css = #"""
:root{
 --e-bg:#fcfbf7;--e-fg:#262422;--e-muted:#777673;--e-link:#414844;--e-strong:#b0392e;--e-border:#d5d4d1;--e-sel:#deada7;
 --e-ex:#23408e;--e-head:var(--e-fg);--e-num:var(--e-strong);
 --e-serif:"Times New Roman","Hiragino Mincho ProN","Hiragino Mincho Pro","Yu Mincho","Noto Serif JP","PingFang TC",serif;
 --e-sans:-apple-system,"Hiragino Sans","Hiragino Kaku Gothic ProN","PingFang TC",sans-serif;
 --e-font:var(--e-serif);
 --e-size:19px;
 color-scheme:light;
}
:root[data-font="sans"]{--e-font:var(--e-sans)}
html,body{overscroll-behavior:contain;overflow-anchor:none}
html,body{background:var(--e-bg)!important;color:var(--e-fg)!important}
body{
 margin:0!important;padding:16px 16px 48px!important;
 font:400 var(--e-size)/1.78 var(--e-font)!important;
 overflow-wrap:anywhere;-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;
 font-kerning:normal;
}
body *{
 color:inherit!important;background-color:transparent!important;background-image:none!important;
 border-color:var(--e-border)!important;font-family:inherit!important;letter-spacing:normal!important;
 text-shadow:none!important;box-shadow:none!important;
}
body :is(p,div,li,dd,dt,section){line-height:inherit!important}
body a,body a *{color:var(--e-link)!important;text-decoration:underline!important;text-decoration-color:color-mix(in srgb,var(--e-link) 35%,transparent)!important;text-decoration-thickness:1px!important;text-underline-offset:3px}
body a:hover{text-decoration-color:currentColor!important}
body b,body strong{font-weight:700!important}
body i,body em,body .em_italic{font-style:italic!important}
body sup,body sub{font-size:.62em!important;line-height:0!important}
body ruby rt{font-size:.55em!important}
img{max-width:100%;height:auto}
table{max-width:100%;border-collapse:collapse}
td,th{padding:3px 8px;vertical-align:top}
hr{border:0;border-top:1px solid var(--e-border)!important;margin:1em 0}
::selection{background:var(--e-sel)!important;color:inherit!important}
::-webkit-scrollbar{width:10px}
::-webkit-scrollbar-thumb{background:color-mix(in srgb,var(--e-fg) 20%,transparent);border-radius:99px;border:2px solid transparent;background-clip:content-box}
::-webkit-scrollbar-track{background:transparent}
audio{color-scheme:inherit;display:inline-block;width:170px;height:30px;vertical-align:middle;margin:0 6px;border-radius:99px}
body .dictionary-source{
 display:flex;align-items:center;gap:10px;
 margin:0 0 16px!important;padding:0 0 10px!important;
 font:600 12px/1.5 var(--e-sans)!important;letter-spacing:.08em!important;
 color:var(--e-muted)!important;border-bottom:1px solid var(--e-border)!important;
}
body .dictionary-source::before{content:"";flex:none;width:9px;height:9px;border-radius:2px;background:var(--e-num)!important;transform:rotate(45deg)}
body :is(.Header,.HeaderTitle,.entry-index,.mjrhsjcd-entry>.title,.tkbt-entry>.title,.cj3-duplicate-entry>.entry-index){display:none!important}
body .Contents{margin:0!important}
body :is(.HeadG,.midashi,.item_midashi,.mjrhsjcd-entry>.head,.tkbt-entry>.head,.dic_item>.head,div.head:has(>h),h3,.dc-entry>.midashi){
 display:block!important;margin:0 0 .35em!important;padding:0!important;line-height:1.35!important;
}
body :is(.HeadG .headword,.hw_midashi,.item_midashi .midashi,.midashi_kana,.titlekana,.dc-headword,.headword_kana,.mjrhsjcd-entry .word,.kanji01,headword,h3,.head>.かな,.headword>.reading){
 font-size:1.55em!important;font-weight:700!important;color:var(--e-head)!important;letter-spacing:.01em!important;
}
body :is(.headword.表記,.m_hyoki,.hyouki_g,.headword_kanji,black_branckets,.hyouki_g *,.pinyin_h,.headword:not(.表記)~.headword){
 font-size:1.2em!important;font-weight:400!important;color:var(--e-head)!important;margin-left:.15em;
}
body .Hsup{font-size:.5em!important;font-weight:600!important;vertical-align:super;color:var(--e-muted)!important;margin-left:.1em}
body .headword_eng{display:block;margin-top:.15em;font-size:1.05em!important;font-weight:600!important;font-style:italic!important;color:var(--e-muted)!important}
body :is(.pinyin_h,.mjrhsjcd-entry .type,.tkbt-entry .read,.tkbt-entry .readj){color:var(--e-muted)!important}
body h3 .pinyin_h{font-size:.7em!important;margin-left:.5em}
body .mjrhsjcd-entry .type{font:600 .72em var(--e-sans)!important;margin-left:.6em;padding:1px 7px;border:1px solid var(--e-border)!important;border-radius:6px;vertical-align:.2em}
body .headword>.reading{margin-right:.25em}
body .headword:has(>.reading){display:block;margin:0 0 .45em;font-size:1.1em!important}
body :is(.meaning,.mean_eng,.mean_gogi,.gogi,.def1,.def2,.dc-line,.MeaningG>.meaning){margin-block:.2em!important}
body :is(.MeaningG,.gogi,.mean_gogi,.meaning,.def1){margin-top:.55em!important}
body :is(.num,.wc,.dc-sense,.fontredcolor,.sense_no,.gogi>.num,.MeaningG .Num,.snum){
 color:var(--e-num)!important;font-weight:700!important;margin-right:.3em;
}
body :is(.slabel,.label,.naihou,.note_div,.shironuki,.daikubun,.tkbt-label,.type,.kg_eiyaku,.shiyouiki,.white-square,.hinshi,.bunya,.yoho,.gram){
 color:var(--e-muted)!important;
}
body :is(.tkbt-label,.white-square,.mjrhsjcd-entry .type){font-family:var(--e-sans)!important}
body :is(.tkbt-label,.white-square){font-size:.75em!important;font-weight:650!important;padding:1px 6px;margin-right:.4em;border:1px solid var(--e-border)!important;border-radius:6px;vertical-align:.12em}
body :is(.tyuuki_g,.note,.chuui,.hosoku){color:var(--e-muted)!important;font-size:.92em!important}
body :is(.pinyin,.mean_pinyin,.pinyin_box){color:var(--e-muted)!important;font-size:.82em!important;font-style:italic!important}
body .pinyin_box{margin-left:.3em}
body .kg_wake{display:none}
body :is(.hatuon_g,.IPA){color:var(--e-muted)!important}
body :is(.eng,.mean_yakugo,.yakugo,.dfcn){color:var(--e-fg)!important}
body .mean_eng .eng,body .item_midashi~.meaning .eng{font-weight:600!important}
body img:is(.sense_pat_mark_s,.sense_pat_mark_e,.img_sound){display:none}
body :is(.MeaningG>.example,div.mean_yorei,.yoorei,.mean_yoreiyaku,.dic_item div.example,.dic_item>.example,.exam,.cj3-duplicate-entry .example,.body>.example,p[data-orgtag="example"],.examples>li.example-ja){
 display:block!important;margin:calc(var(--e-size) * .5) 0 calc(var(--e-size) * .5) calc(var(--e-size) * 1.15)!important;padding:0!important;text-indent:0!important;
}
body :is(.用例,.scope_exam_jp,.reibun,span.mean_yorei,.dic_item div.example>span.example:first-of-type,.exjp,.ex_boby,.example_jp,jae,li.example-ja,x-none){
 display:block!important;color:var(--e-ex)!important;
}
body :is(.用例訳,.scope_exam_en,.yakubun_g,.reiyaku_box,.dic_item div.example>span.example:nth-of-type(2),.excn,.exen,.ex_trans,.example_en,ja_cn,li.example-en){
 display:block!important;color:var(--e-fg)!important;
}
body :is(.用例,.scope_exam_jp,.reibun,.exjp,.example_jp,jae,li.example-ja) :is(b,strong,.bi){color:inherit!important}
body :is(.excn,.exen){font-size:.94em!important}
body .exen{color:var(--e-muted)!important}
body :is(.mj_yorei_sep,.kg_reiyaku_box,.kg_yoreiyaku,.example_mark,.sound_mark){display:none!important}
body .yoorei{text-indent:0!important}
body .yoorei>:is(.reibun){display:block!important}
body .yoorei{position:relative}
body .examples{list-style:none;margin:.3em 0 0!important;padding:0!important}
body .examples>li.example-en{margin:0 0 .55em 1.15em!important}
body .mjrhsjcd-entry .exam{font-size:0}
body .mjrhsjcd-entry .exam>*{font-size:var(--e-size)}
body .mjrhsjcd-entry .dfjp{display:block;color:var(--e-fg)!important}
body .mjrhsjcd-entry .dfcn{display:block;color:var(--e-muted)!important}
body .mjrhsjcd-entry .def2{display:inline}
body .tkbt-entry .phrases{margin-top:.6em}
body .tkbt-entry .dfen{margin:.3em 0!important}
body .tkbt-entry .dfen .dfcn{display:block;color:var(--e-muted)!important}
body section.description p[data-orgtag="meaning"]{margin:.3em 0!important}
body :is(.ref,.ref_item,.sansyou_g,.dc-xref,.canzhao){color:var(--e-link)!important}
body :is(.SubItem,.ComplexG){margin-top:1.1em!important}
body :is(.subheadword,.ComplexH){font-weight:700!important;color:var(--e-head)!important}
body :is(.subheadword,.ComplexH)::before{content:"";display:inline-block;width:.5em;height:.5em;margin-right:.45em;border-radius:1px;background:var(--e-num)!important;transform:rotate(45deg) translateY(-.12em)}
body details.import-source{display:block;margin:14px 0;padding:10px 14px!important;border:1px solid var(--e-border)!important;border-radius:10px}
body details.import-source>summary{cursor:pointer;font:700 13px/1.6 var(--e-sans)!important;letter-spacing:.05em!important;color:var(--e-muted)!important}
body dic-item{display:block}
body :is(accent_text,con_table>accent){display:inline-flex;align-items:center;gap:6px;font-size:1.25em!important;letter-spacing:.06em!important}
body con_table{display:flex;flex-wrap:wrap;gap:8px;margin-top:.8em}
body con_table>accent{font-size:1.02em!important;padding:4px 10px;border:1px solid var(--e-border)!important;border-radius:10px}
body :is(symbol_backslash,symbol_macron){color:var(--e-num)!important;font-weight:700!important}
body .dc-half{font-size:1em!important}
body .indent1{margin-left:.2em!important}
body .indent2{margin-left:1.2em!important}
body .indent3{margin-left:2.2em!important}
#dictionary-dark-theme{font-family:var(--e-font)!important}
body :is(.MeaningG>.example,div.mean_yorei,.yoorei,.mean_yoreiyaku,.dic_item div.example,.exam,.cj3-duplicate-entry .example,.body>.example,p[data-orgtag="example"],.examples>li){line-height:1.62!important}
body :is(li.example-ja,li.example-en){font-size:1em!important}
body .yoorei{font-size:0!important}
body .yoorei>*{font-size:var(--e-size)!important}
body .yoorei .yakubun_g *{font-size:1em!important}
body .yoorei .tyuuki_g{font-size:.92em!important}
body section.description :is(b,strong,span){color:var(--e-fg)!important}
body section.description .white-square{color:var(--e-muted)!important}
body section.description jae{color:var(--e-ex)!important}
body .mean_reiyaku{color:var(--e-fg)!important}
body span.mean_yorei *{color:inherit!important}
@media (prefers-color-scheme: dark){
 :root{--e-bg:#1d1c1a;--e-fg:#ece8e1;--e-muted:#a09a90;--e-link:#b8cbc2;--e-strong:#ec8a7c;--e-border:#3b3935;--e-sel:#6e4540;--e-ex:#9ec2ff;color-scheme:dark}
}
body con_table>accent,body accent_text{white-space:nowrap}body con_table>accent{display:flex;justify-content:space-between;width:100%}
body,body *{-webkit-user-select:text;user-select:text}
:root[data-font="sans"]{--e-font:var(--e-sans)}
"""#

    /// Variables for a fixed-colour theme. `nil` background keeps the CSS defaults,
    /// which already follow iOS Light/Dark.
    static func variables(backgroundRGB: Int?, accentRGB: Int?, size: Double, sans: Bool) -> String {
        var rules = "--e-size:\(Int(size.rounded()))px;"
        if let bg = backgroundRGB {
            let dark = Palette.isDark(bg)
            let ink = Palette.mix(dark ? 0xFFFFFF : 0x000000, toward: bg, 0.12)
            let accent = accentRGB ?? (dark ? 0x9EC2FF : 0x23408E)
            let strong = Palette.rgb(Palette.accessibleAccent(accent, dark: dark, backgroundRGB: bg))
            let exBase = Palette.mix(dark ? 0xA9C8F5 : 0x1F3F8F, toward: accent, 0.15)
            let example = Palette.rgb(Palette.accessibleAccent(exBase, dark: dark, backgroundRGB: bg))
            rules += "--e-bg:\(Palette.hexString(bg));--e-fg:\(Palette.hexString(ink));"
            rules += "--e-muted:\(Palette.hexString(Palette.mix(ink, toward: bg, 0.40)));"
            rules += "--e-border:\(Palette.hexString(Palette.mix(ink, toward: bg, 0.84)));"
            rules += "--e-link:\(Palette.hexString(strong));--e-strong:\(Palette.hexString(strong));"
            rules += "--e-ex:\(Palette.hexString(example));--e-sel:\(Palette.hexString(strong))40;"
            rules += "color-scheme:\(dark ? "dark" : "light");"
        } else if let accent = accentRGB {
            let light = Palette.hexString(Palette.rgb(Palette.accessibleAccent(accent, dark: false, backgroundRGB: 0xFCFBF7)))
            let dark = Palette.hexString(Palette.rgb(Palette.accessibleAccent(accent, dark: true, backgroundRGB: 0x1D1C1A)))
            rules += "--e-strong:\(light);--e-link:\(light);"
            return ":root{\(rules)}@media (prefers-color-scheme: dark){:root{--e-strong:\(dark);--e-link:\(dark)}}" + (sans ? ":root{--e-font:var(--e-sans)}" : "")
        }
        return ":root{\(rules)}" + (sans ? ":root{--e-font:var(--e-sans)}" : "")
    }
}
