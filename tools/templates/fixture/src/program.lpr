program {{PASCAL_PROGRAM}};

{ {{PROJECT_NAME}} - the native half of a PWeb application.

  This is the CAP-10B0 fixture template. It is a NEUTRAL placeholder: it
  builds nothing, opens no window and binds no service, because CAP-10B0
  freezes the scaffolding ENGINE and deliberately ships no runnable public
  template. CAP-10B1 and CAP-10B2 replace this with the React and Pas2JS
  hosts.

  What it does demonstrate is the identity mapping, which is the part that
  has to be right before any template is worth writing:

    the program identifier, the executable base name and the descriptor's
    `name` are one stated value, and this file is named after it. }

{$mode ObjFPC}{$H+}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  sysutils;

const
  PROJECT_NAME = '{{PROJECT_NAME}}';
  PROJECT_VERSION = '{{PROJECT_VERSION}}';
  BUNDLE_ID = '{{BUNDLE_ID}}';
  UI_KIND = '{{UI_KIND}}';

begin
  WriteLn(PROJECT_NAME, ' ', PROJECT_VERSION);
  WriteLn('bundle: ', BUNDLE_ID);
  WriteLn('frontend: ', UI_KIND);
end.
