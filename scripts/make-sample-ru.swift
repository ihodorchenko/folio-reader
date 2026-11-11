// Generates a reference Russian-language PDF (Cyrillic, level 1–3 headings,
// a list, a caption, a monospaced block, a footer) and a PDF without a text layer.
// Usage: swift scripts/make-sample-ru.swift samples
import AppKit
import CoreGraphics

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "samples"
let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let pageW = 595.0
let pageH = 842.0

func makePDF(_ path: String, pages: Int, draw: (CGContext, Int) -> Void) {
    var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
    guard let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &mediaBox, nil) else {
        fatalError("cannot create PDF context at \(path)")
    }
    for i in 0..<pages {
        ctx.beginPDFPage(nil)
        // The graphics state color is reset by beginPDFPage — set the fill inside the page,
        // otherwise the page background stays black (the default).
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(mediaBox)
        draw(ctx, i)
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

func withNS(_ ctx: CGContext, _ body: () -> Void) {
    let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = ns
    // AppKit does not emit a color operator for "default black" and relies on the current
    // fill color. After filling the page white that color is white — so set black explicitly,
    // otherwise the black text ends up invisible.
    ctx.setFillColorSpace(CGColorSpaceCreateDeviceRGB())
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    body()
    NSGraphicsContext.current = saved
}

func draw(_ text: String, rect: CGRect, size: CGFloat, bold: Bool = false,
          mono: Bool = false, color: NSColor = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1), align: NSTextAlignment = .left,
          lineSpacing: CGFloat = 2) {
    // Important: the system SF Pro font produces a broken ToUnicode mapping for Cyrillic when
    // subsetted (к → ĸ). Explicit typefaces write a correct mapping.
    let font: NSFont
    if mono {
        font = NSFont(name: "Menlo", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    } else if bold {
        font = NSFont(name: "HelveticaNeue-Bold", size: size) ?? NSFont.boldSystemFont(ofSize: size)
    } else {
        font = NSFont(name: "HelveticaNeue", size: size) ?? NSFont.systemFont(ofSize: size)
    }
    let para = NSMutableParagraphStyle()
    para.alignment = align
    para.lineSpacing = lineSpacing
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: para,
    ]
    (text as NSString).draw(in: rect, withAttributes: attrs)
}

func footer(_ ctx: CGContext, page: Int, of total: Int) {
    withNS(ctx) {
        draw("Folio · демонстрационный документ", rect: CGRect(x: 64, y: 24, width: 400, height: 16),
             size: 8, color: .gray)
        draw("Стр. \(page + 1) из \(total)", rect: CGRect(x: 480, y: 24, width: 90, height: 16),
             size: 8, color: .gray, align: .right)
    }
}

// ---------------- Document 1: structured Russian text ----------------
let structured = "\(outDir)/sample-ru.pdf"
makePDF(structured, pages: 3) { ctx, page in
    withNS(ctx) {
        switch page {
        case 0:
            draw("Структура PDF-документа", rect: CGRect(x: 64, y: 78, width: 470, height: 42),
                 size: 28, bold: true)
            draw("Практическое руководство по извлечению заголовков и элементов", rect: CGRect(x: 64, y: 122, width: 470, height: 24),
                 size: 13, color: .darkGray)
            draw("1. Введение", rect: CGRect(x: 64, y: 176, width: 470, height: 30), size: 18, bold: true)
            draw("""
            Формат PDF описывает не документ, а способ его отображения на странице. \
            Поэтому надёжное определение заголовков — это всегда комбинация типографики, \
            геометрии и, если повезёт, логической разметки самого файла. Ниже разобраны \
            оба подхода и то, как они сочетаются в ридере Folio.
            """, rect: CGRect(x: 64, y: 212, width: 470, height: 90), size: 11)
            draw("1.1. Типографические признаки", rect: CGRect(x: 64, y: 312, width: 470, height: 26), size: 14, bold: true)
            draw("""
            Кегль, насыщенность и гарнитура шрифта дают основной сигнал. Заголовок первого \
            уровня обычно крупнее основного текста в 1,5–2 раза, подзаголовок — в 1,2–1,4. \
            Дополнительно учитываются вертикальные просветы и нумерация вида «1.2.3».
            """, rect: CGRect(x: 64, y: 344, width: 470, height: 84), size: 11)
            draw("1.2. Логическая разметка", rect: CGRect(x: 64, y: 444, width: 470, height: 26), size: 14, bold: true)
            draw("""
            Тегированные PDF содержат дерево структуры: элементы H1…H6, P, LI, Table. Если \
            файл размечен, уровень заголовка берётся непосредственно из дерева и не требует \
            эвристик. На практике размечено меньшинство документов.
            """, rect: CGRect(x: 64, y: 476, width: 470, height: 84), size: 11)
            draw("Список признаков заголовка", rect: CGRect(x: 64, y: 578, width: 470, height: 24), size: 12, bold: true)
            draw("""
            • размер шрифта больше медианного по странице;
            • насыщенность выше основной;
            • одиночная короткая строка с отбивкой;
            • нумерация или римская цифра в начале строки.
            """, rect: CGRect(x: 64, y: 608, width: 470, height: 90), size: 11)
            draw("Рис. 1. Пример подписи к иллюстрации", rect: CGRect(x: 64, y: 714, width: 470, height: 16),
                 size: 9, color: .darkGray, align: .center)
        case 1:
            draw("2. Сильное нажатие и словарь", rect: CGRect(x: 64, y: 78, width: 470, height: 30), size: 18, bold: true)
            draw("""
            Сильное нажатие (force click) на слове вызывает системную панель определения — \
            ровно так же, как в Preview и Books. Приложение получает событие давления с \
            этапом 2 и передаёт слово в NSView.showDefinition(for:at:). Система сама \
            показывает словарь, подбирает статью и запоминает источник.
            """, rect: CGRect(x: 64, y: 118, width: 470, height: 96), size: 11)
            draw("2.1. Как это устроено", rect: CGRect(x: 64, y: 238, width: 470, height: 26), size: 14, bold: true)
            draw("""
            Нажатие начинается как обычный mouseDown. Пока палец давит сильнее, приходят \
            события pressureChange: сначала этап 1 («нажатие»), затем этап 2 («сильное \
            нажатие»). На этапе 2 вызывается словарь, этап 0 завершает жест.
            """, rect: CGRect(x: 64, y: 270, width: 470, height: 84), size: 11)
            draw("2.2. Требования к железу", rect: CGRect(x: 64, y: 370, width: 470, height: 26), size: 14, bold: true)
            draw("""
            Нужен трекпад с Force Touch и включённым в системных настройках «Сильное \
            нажатие и тактильный отклик». На обычной мыши остаётся сочетание ⌘D.
            """, rect: CGRect(x: 64, y: 402, width: 470, height: 70), size: 11)
            draw("3. Пример кода", rect: CGRect(x: 64, y: 492, width: 470, height: 30), size: 18, bold: true)
            draw("override func pressureChange(with event: NSEvent) {\n    if event.stage == 2 {\n        lookUpWord(at: lastPressPoint)\n    }\n}", rect: CGRect(x: 64, y: 532, width: 470, height: 80), size: 10, mono: true)
            draw("Рис. 2. Фрагмент обработки сильного нажатия", rect: CGRect(x: 64, y: 626, width: 470, height: 16),
                 size: 9, color: .darkGray, align: .center)
        default:
            draw("3.1. Словарь терминов", rect: CGRect(x: 64, y: 78, width: 470, height: 26), size: 14, bold: true)
            draw("""
            Словарь — системная служба macOS, доступная любому приложению. Определение — \
            статья словаря для выбранного слова. Разметка — набор прямоугольников и типов \
            элементов, восстановленный по странице.
            """, rect: CGRect(x: 64, y: 112, width: 470, height: 84), size: 11)
            draw("3.2. Что дальше", rect: CGRect(x: 64, y: 214, width: 470, height: 26), size: 14, bold: true)
            draw("""
            Следующие шаги: озвучивание текста, ссылки между страницами, аннотации и \
            сохранение прогресса чтения. Всё это опирается на ту же разметку блоков.
            """, rect: CGRect(x: 64, y: 246, width: 470, height: 70), size: 11)
            draw("Литература", rect: CGRect(x: 64, y: 360, width: 470, height: 24), size: 12, bold: true)
            draw("""
            [1] ISO 32000-1:2008. Document management — Portable Document Format.
            [2] PDF 1.7 Reference, Adobe Systems, 2006.
            [3] Apple. NSView.showDefinition(for:at:). AppKit Documentation.
            """, rect: CGRect(x: 64, y: 390, width: 470, height: 70), size: 9)
        }
    }
    footer(ctx, page: page, of: 3)
}

// ---------------- Document 2: a page without a text layer ----------------
let scan = "\(outDir)/no-text.pdf"
makePDF(scan, pages: 1) { ctx, _ in
    // Graphics only: not a single text object (a simulated scan).
    ctx.setFillColor(NSColor(calibratedWhite: 0.92, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 50, y: 50, width: 495, height: 742))
    ctx.setStrokeColor(NSColor.gray.cgColor)
    ctx.setLineWidth(3)
    for i in 0..<9 {
        let y = 140 + Double(i) * 62
        ctx.stroke(CGRect(x: 90, y: y, width: Double(140 + (i * 37) % 300), height: 26))
    }
    ctx.setFillColor(NSColor(calibratedWhite: 0.55, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 90, y: 120, width: 415, height: 300))
}

print("OK: \(structured), \(scan)")
