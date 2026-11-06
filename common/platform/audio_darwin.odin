package platform_common

// macOS: miniaudio's CoreAudio backend needs these linked (@(require) keeps them though
// nothing here names a symbol of theirs). client/audio imports this package for them.
@(require) foreign import _coreaudio "system:CoreAudio.framework"
@(require) foreign import _audiotoolbox "system:AudioToolbox.framework"
@(require) foreign import _corefoundation "system:CoreFoundation.framework"
