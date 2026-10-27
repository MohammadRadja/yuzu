import Foundation

enum ToolArity {
    case single
    case multiple
    case any
}

enum ToolID: String, CaseIterable, Identifiable {
    case compress
    case editMetadata
    case editImage
    case frameImage
    case cropImage
    case redactImage
    case resizeImage
    case rotateImage
    case createPDF
    case createCollage
    case trimVideo
    case cropVideo
    case changeVideoSpeed
    case joinVideos
    case videoSnapshots
    case splitVideo
    case redactVideo
    case normalizeAudio
    case audioToVideo
    case trimAudio
    case audioChannels
    case redactAudio
    case mergePDF
    case organizePDF
    case splitPDF
    case watermark, ocr, pdfPassword
    case removeBackground, upscaleImage, pdfSign, fileComparison

    var id: String { rawValue }

    var title: String {
        switch self {
        case .removeBackground: return "Remove Background"
        case .upscaleImage: return "Upscale Image (Lanczos)"
        case .pdfSign: return "PDF Visual Signature"
        case .fileComparison: return "Compare Files"
        case .watermark: return "Watermark"
        case .ocr: return "Recognize text (OCR)"
        case .pdfPassword: return "PDF Password"
        case .compress: return "Compress"
        case .editMetadata: return "Edit metadata"
        case .editImage: return "Edit photo"
        case .frameImage: return "Add a background"
        case .cropImage: return "Crop image"
        case .redactImage: return "Redact photo"
        case .resizeImage: return "Resize images"
        case .rotateImage: return "Rotate & flip"
        case .createPDF: return "Create a PDF"
        case .createCollage: return "Create a collage"
        case .trimVideo: return "Trim video"
        case .cropVideo: return "Crop video"
        case .changeVideoSpeed: return "Change video speed"
        case .joinVideos: return "Join videos"
        case .videoSnapshots: return "Save video frames"
        case .splitVideo: return "Split video"
        case .redactVideo: return "Redact video"
        case .normalizeAudio: return "Normalize volume"
        case .audioToVideo: return "Audio visualizer"
        case .trimAudio: return "Trim audio"
        case .audioChannels: return "Audio channels"
        case .redactAudio: return "Bleep audio"
        case .mergePDF: return "Merge PDFs"
        case .organizePDF: return "Organize PDF pages"
        case .splitPDF: return "Split PDF"
        }
    }

    var progressTitle: String {
        switch self {
        case .removeBackground: return "Removing background"
        case .upscaleImage: return "Upscaling image"
        case .pdfSign: return "Adding visual signature"
        case .fileComparison: return "Comparing files"
        case .watermark: return "Adding watermark"
        case .ocr: return "Recognizing text"
        case .pdfPassword: return "Changing PDF protection"
        case .compress: return "Compressing"
        case .editMetadata: return "Editing metadata"
        case .editImage: return "Editing photo"
        case .frameImage: return "Adding background"
        case .cropImage, .cropVideo: return "Cropping"
        case .redactImage, .redactVideo: return "Redacting"
        case .resizeImage: return "Resizing"
        case .rotateImage: return "Rotating"
        case .createPDF: return "Creating PDF"
        case .createCollage: return "Creating collage"
        case .trimVideo, .trimAudio: return "Trimming"
        case .changeVideoSpeed: return "Changing speed"
        case .joinVideos: return "Joining"
        case .videoSnapshots: return "Saving frames"
        case .splitVideo, .splitPDF: return "Splitting"
        case .normalizeAudio: return "Normalizing"
        case .audioToVideo: return "Creating visualizer"
        case .audioChannels: return "Converting channels"
        case .redactAudio: return "Bleeping"
        case .mergePDF: return "Merging"
        case .organizePDF: return "Organizing"
        }
    }

    var radialLabel: String {
        switch self {
        case .removeBackground: return "REMOVE BG"
        case .upscaleImage: return "UPSCALE"
        case .pdfSign: return "SIGN PDF"
        case .fileComparison: return "COMPARE"
        case .watermark: return "WATERMARK"
        case .ocr: return "OCR"
        case .pdfPassword: return "PASSWORD"
        case .compress: return "COMPRESS"
        case .editMetadata: return "METADATA"
        case .editImage: return "EDIT"
        case .frameImage: return "ADD BG"
        case .cropImage, .cropVideo: return "CROP"
        case .redactImage, .redactVideo: return "REDACT"
        case .resizeImage: return "RESIZE"
        case .rotateImage: return "ROTATE"
        case .createPDF: return "PDF"
        case .createCollage: return "COLLAGE"
        case .trimVideo, .trimAudio: return "TRIM"
        case .changeVideoSpeed: return "SPEED"
        case .joinVideos: return "JOIN"
        case .videoSnapshots: return "FRAMES"
        case .splitVideo, .splitPDF: return "SPLIT"
        case .normalizeAudio: return "NORMALIZE"
        case .audioToVideo: return "VISUALIZE"
        case .audioChannels: return "CHANNELS"
        case .redactAudio: return "BLEEP"
        case .mergePDF: return "MERGE"
        case .organizePDF: return "ORGANIZE"
        }
    }

    var symbol: String {
        switch self {
        case .removeBackground: return "person.crop.rectangle"
        case .upscaleImage: return "arrow.up.left.and.arrow.down.right"
        case .pdfSign: return "signature"
        case .fileComparison: return "doc.text.magnifyingglass"
        case .watermark: return "text.badge.plus"
        case .ocr: return "text.viewfinder"
        case .pdfPassword: return "lock.doc"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .editMetadata: return "tag"
        case .editImage: return "slider.horizontal.3"
        case .frameImage: return "photo.artframe"
        case .cropImage, .cropVideo: return "crop"
        case .redactImage: return "eye.slash"
        case .redactVideo: return "video.slash"
        case .resizeImage: return "arrow.up.left.and.arrow.down.right"
        case .rotateImage: return "rotate.right"
        case .createPDF: return "doc.richtext"
        case .createCollage: return "square.grid.2x2"
        case .trimVideo, .trimAudio: return "scissors"
        case .changeVideoSpeed: return "gauge.with.dots.needle.67percent"
        case .joinVideos: return "link"
        case .videoSnapshots: return "camera.viewfinder"
        case .splitVideo: return "rectangle.split.2x1"
        case .splitPDF: return "doc.on.doc"
        case .normalizeAudio: return "waveform"
        case .audioToVideo: return "waveform.and.magnifyingglass"
        case .audioChannels: return "headphones"
        case .redactAudio: return "speaker.slash"
        case .mergePDF: return "doc.on.doc.fill"
        case .organizePDF: return "rectangle.stack"
        }
    }

    var categories: Set<FormatCategory> {
        switch self {
        case .removeBackground, .upscaleImage: return [.image]
        case .pdfSign: return [.document]
        case .fileComparison: return Set(FormatCategory.allCases)
        case .watermark, .ocr: return [.image, .document]
        case .pdfPassword: return [.document]
        case .compress, .editMetadata:
            return [.image, .video, .audio, .document]
        case .editImage, .frameImage, .cropImage, .redactImage, .resizeImage, .rotateImage, .createPDF, .createCollage:
            return [.image]
        case .trimVideo, .cropVideo, .changeVideoSpeed, .joinVideos, .videoSnapshots, .splitVideo, .redactVideo:
            return [.video]
        case .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio:
            return [.audio]
        case .mergePDF, .organizePDF, .splitPDF:
            return [.document]
        }
    }

    var arity: ToolArity {
        switch self {
        case .compress, .editMetadata, .resizeImage, .rotateImage, .createPDF: return .any
        case .createCollage, .joinVideos, .mergePDF: return .multiple
        default: return .single
        }
    }

    func applies(to formats: [FileFormat]) -> Bool {
        guard !formats.isEmpty else { return false }
        if self == .fileComparison { return formats.count == 2 }
        let categories = Set(formats.map(\.category))
        guard categories.count == 1, let category = categories.first, self.categories.contains(category) else { return false }
        if category == .document {
            switch self {
            case .mergePDF, .organizePDF, .splitPDF, .editMetadata, .compress, .watermark, .ocr, .pdfPassword, .pdfSign:
                guard formats.allSatisfy({ $0 == .pdf }) else { return false }
            default:
                return false
            }
        }
        if category == .video, formats.contains(.gif), self != .compress, self != .editMetadata { return false }
        switch arity {
        case .single: return formats.count == 1
        case .multiple: return formats.count >= 2
        case .any: return true
        }
    }

    static func available(for formats: [FileFormat]) -> [ToolID] {
        allCases.filter { $0.applies(to: formats) }
    }

    static var total: Int { allCases.count }
}
