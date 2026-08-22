Unicode true
SetCompressor /SOLID zlib
RequestExecutionLevel user
!cd "${__FILEDIR__}/.."

!include "MUI2.nsh"

!define PRODUCT_NAME "Reading Companion Open"
!define PRODUCT_VERSION "0.43.18"
!define PRODUCT_PUBLISHER "Reading Companion contributors"
!define PRODUCT_EXE "Reading Companion Open.exe"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Reading Companion Open"
!define MUI_ICON "dist/.icon-ico/icon.ico"
!define MUI_UNICON "dist/.icon-ico/icon.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\${PRODUCT_EXE}"

Name "${PRODUCT_NAME}"
Caption "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile "dist/Reading-Companion-Open-${PRODUCT_VERSION}-Windows-x64-Setup.exe"
InstallDir "$LOCALAPPDATA\Programs\Reading Companion Open"
InstallDirRegKey HKCU "Software\Reading Companion Open" "InstallLocation"
BrandingText "Reading Companion Open"
ShowInstDetails show
ShowUninstDetails show

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"

Section "安装" MainSection
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File /r "dist/win-unpacked/*"

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\Reading Companion Open" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${PRODUCT_NAME}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${PRODUCT_VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "${PRODUCT_PUBLISHER}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\${PRODUCT_EXE}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" 506680

  CreateDirectory "$SMPROGRAMS\Reading Companion Open"
  CreateShortcut "$SMPROGRAMS\Reading Companion Open\Reading Companion Open.lnk" "$INSTDIR\${PRODUCT_EXE}"
  CreateShortcut "$SMPROGRAMS\Reading Companion Open\卸载 Reading Companion Open.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\Reading Companion Open.lnk" "$INSTDIR\${PRODUCT_EXE}"
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  Delete "$DESKTOP\Reading Companion Open.lnk"
  RMDir /r "$SMPROGRAMS\Reading Companion Open"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  DeleteRegKey HKCU "Software\Reading Companion Open"
  RMDir /r "$INSTDIR"
SectionEnd
