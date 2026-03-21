TARGET := iphone:clang:latest:16.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RemoteCamTweak
RemoteCamTweak_FILES = Tweak.xm
RemoteCamTweak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
RemoteCamTweak_FRAMEWORKS = Foundation AVFoundation CoreMedia CoreVideo
RemoteCamTweak_LIBRARIES = substrate

export THEOS_PACKAGE_SCHEME=rootless

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
