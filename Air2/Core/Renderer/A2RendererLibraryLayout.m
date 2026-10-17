//
//  A2RendererLibraryLayout.m
//  Air2
//

#import "A2RendererLibraryLayout.h"

BOOL A2RendererLayoutHasSeparateEGL(A2RendererLibraryLayout layout) {
    return layout == A2RendererLibraryLayoutSeparate;
}

NSString *A2RendererLayoutDescription(A2RendererLibraryLayout layout) {
    switch (layout) {
        case A2RendererLibraryLayoutCombined:
            return @"合并库（同一个 dylib 导出 GL 与 EGL）";
        case A2RendererLibraryLayoutSeparate:
            return @"分离库（GL 与 EGL 各一个 dylib，先 EGL 后 GL）";
        case A2RendererLibraryLayoutGLOny:
            return @"仅 GL（不需要 EGL）";
    }
    return @"未知布局";
}
