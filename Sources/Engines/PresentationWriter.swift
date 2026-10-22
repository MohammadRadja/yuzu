import Foundation
import PDFKit

/// Each PDF page becomes a full-slide image; source layout is preserved, not editable objects.
enum PresentationWriter {
    static func write(_ document: PDFDocument, to destination: URL, progress: (Double) -> Void) async throws {
        guard document.pageCount > 0, document.pageCount <= 1_000, let first = document.page(at: 0) else {
            throw YuzuError.invalidInput("Choose a PDF with 1 to 1000 pages for a presentation.")
        }
        let bounds = first.bounds(for: .mediaBox)
        let rotated = first.rotation % 180 != 0
        let width = rotated ? bounds.height : bounds.width
        let height = rotated ? bounds.width : bounds.height
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 4_000, height <= 4_000 else {
            throw YuzuError.invalidInput("The PDF page dimensions are too large for a presentation.")
        }
        let cx = Int(width * 12_700)
        let cy = Int(height * 12_700)
        let ns = "http://schemas.openxmlformats.org"
        let declarations =
            "xmlns:p=\"\(ns)/presentationml/2006/main\" xmlns:a=\"\(ns)/drawingml/2006/main\" xmlns:r=\"\(ns)/officeDocument/2006/relationships\""
        let group =
            "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        func relationships(_ body: String) -> Data {
            DocumentPackage.data("<?xml version=\"1.0\"?><Relationships xmlns=\"\(ns)/package/2006/relationships\">\(body)</Relationships>")
        }
        func relationship(_ id: String, _ type: String, _ target: String) -> String {
            "<Relationship Id=\"\(id)\" Type=\"\(ns)/officeDocument/2006/relationships/\(type)\" Target=\"\(target)\"/>"
        }
        var files: [String: Data] = [:]
        var slideIDs = ""
        var presentationRels = relationship("rId1", "slideMaster", "slideMasters/slideMaster1.xml")
        var overrides = ""
        var imageBytes = 0
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("yuzu-slides-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw YuzuError.unreadable(destination) }
            let size = page.bounds(for: .mediaBox).size
            guard size.width > 0, size.height > 0, size.width <= 4_000, size.height <= 4_000,
                let image = PDFRenderer.render(page: page, dpi: 144)
            else {
                throw YuzuError.invalidInput("A PDF page is too large or cannot be rendered.")
            }
            let number = index + 1
            let imageURL = staging.appendingPathComponent("page\(number).png")
            try ImageIOBridge.write(image, to: imageURL, format: .png)
            let data = try Data(contentsOf: imageURL)
            imageBytes += data.count
            guard imageBytes <= 256 * 1_024 * 1_024 else {
                throw YuzuError.invalidInput("The rendered presentation exceeds 256 MB. Split the PDF into smaller files.")
            }
            files["ppt/media/page\(number).png"] = data
            let scale = min(Double(cx) / Double(image.width), Double(cy) / Double(image.height))
            let imageWidth = Int(Double(image.width) * scale)
            let imageHeight = Int(Double(image.height) * scale)
            let picture = """
                <p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(number)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="\((cx - imageWidth) / 2)" y="\((cy - imageHeight) / 2)"/><a:ext cx="\(imageWidth)" cy="\(imageHeight)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
                """
            files["ppt/slides/slide\(number).xml"] = DocumentPackage.data(
                "<?xml version=\"1.0\"?><p:sld \(declarations)><p:cSld><p:spTree>\(group)\(picture)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
            )
            files["ppt/slides/_rels/slide\(number).xml.rels"] = relationships(
                relationship("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml") + relationship("rId2", "image", "../media/page\(number).png"))
            slideIDs += "<p:sldId id=\"\(256 + index)\" r:id=\"rId\(number + 1)\"/>"
            presentationRels += relationship("rId\(number + 1)", "slide", "slides/slide\(number).xml")
            overrides +=
                "<Override PartName=\"/ppt/slides/slide\(number).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            progress(Double(number) / Double(document.pageCount) * 0.9)
        }
        let parts = [
            ("presentation.xml", "presentation.main"), ("slideMasters/slideMaster1.xml", "slideMaster"), ("slideLayouts/slideLayout1.xml", "slideLayout"),
        ]
        for (part, type) in parts {
            overrides += "<Override PartName=\"/ppt/\(part)\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.\(type)+xml\"/>"
        }
        overrides += "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        files["[Content_Types].xml"] = DocumentPackage.data(
            "<?xml version=\"1.0\"?><Types xmlns=\"\(ns)/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/>\(overrides)</Types>"
        )
        files["_rels/.rels"] = relationships(relationship("rId1", "officeDocument", "ppt/presentation.xml"))
        files["ppt/presentation.xml"] = DocumentPackage.data(
            "<?xml version=\"1.0\"?><p:presentation \(declarations)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx=\"\(cx)\" cy=\"\(cy)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"
        )
        files["ppt/_rels/presentation.xml.rels"] = relationships(presentationRels)
        files["ppt/slideMasters/slideMaster1.xml"] = DocumentPackage.data(
            "<?xml version=\"1.0\"?><p:sldMaster \(declarations)><p:cSld><p:spTree>\(group)</p:spTree></p:cSld><p:clrMap accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" bg1=\"lt1\" bg2=\"lt2\" folHlink=\"folHlink\" hlink=\"hlink\" tx1=\"dk1\" tx2=\"dk2\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>"
        )
        files["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = relationships(
            relationship("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml") + relationship("rId2", "theme", "../theme/theme1.xml"))
        files["ppt/slideLayouts/slideLayout1.xml"] = DocumentPackage.data(
            "<?xml version=\"1.0\"?><p:sldLayout \(declarations) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
        )
        files["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = relationships(relationship("rId1", "slideMaster", "../slideMasters/slideMaster1.xml"))
        let colors = [
            ("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "222222"), ("lt2", "EEEEEE"), ("accent1", "F8C537"), ("accent2", "FF9F1C"), ("accent3", "4472C4"),
            ("accent4", "70AD47"), ("accent5", "8064A2"), ("accent6", "4BACC6"), ("hlink", "0563C1"), ("folHlink", "954F72"),
        ]
        let scheme = colors.map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let fonts = "<a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/>"
        files["ppt/theme/theme1.xml"] = DocumentPackage.data(
            "<?xml version=\"1.0\"?><a:theme xmlns:a=\"\(ns)/drawingml/2006/main\" name=\"Yuzu\"><a:themeElements><a:clrScheme name=\"Yuzu\">\(scheme)</a:clrScheme><a:fontScheme name=\"Yuzu\"><a:majorFont>\(fonts)</a:majorFont><a:minorFont>\(fonts)</a:minorFont></a:fontScheme><a:fmtScheme name=\"Yuzu\"><a:fillStyleLst>\(String(repeating: fill, count: 3))</a:fillStyleLst><a:lnStyleLst>\(String(repeating: "<a:ln w=\"9525\">\(fill)<a:prstDash val=\"solid\"/></a:ln>", count: 3))</a:lnStyleLst><a:effectStyleLst>\(String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3))</a:effectStyleLst><a:bgFillStyleLst>\(String(repeating: fill, count: 3))</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
        )
        try Task.checkCancellation()
        try await DocumentPackage.write(files, to: destination)
    }
}
