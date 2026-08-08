package ui

import (
	"image/color"
	"reflect"
	"testing"
)

func TestResolveKnownTheme(t *testing.T) {
	got := Resolve("default")
	if got.Name != "default" {
		t.Fatalf("Resolve(\"default\").Name = %q, want %q", got.Name, "default")
	}
}

func TestResolveUnknownNameFallsBackToDefault(t *testing.T) {
	// 未知のテーマ名で無色になると、ペインが真っ白なテキストで描画されて
	// しまう。必ず既定テーマへ落とす。
	got := Resolve("no-such-theme")
	if got.Name != DefaultThemeName {
		t.Fatalf("Resolve(unknown).Name = %q, want %q", got.Name, DefaultThemeName)
	}
}

func TestResolveEmptyNameFallsBackToDefault(t *testing.T) {
	got := Resolve("")
	if got.Name != DefaultThemeName {
		t.Fatalf("Resolve(\"\").Name = %q, want %q", got.Name, DefaultThemeName)
	}
}

func TestResolveIsCaseInsensitive(t *testing.T) {
	got := Resolve("DEFAULT")
	if got.Name != "default" {
		t.Fatalf("Resolve(\"DEFAULT\").Name = %q, want %q", got.Name, "default")
	}
}

// 全テーマがすべての色トークンを定義していることを保証する。トークンを
// 追加したときにテーマ側の定義漏れをここで検出する。
func TestEveryThemeDefinesEveryColorToken(t *testing.T) {
	colorType := reflect.TypeOf((*color.Color)(nil)).Elem()

	for name, th := range Themes {
		v := reflect.ValueOf(th)
		typ := v.Type()
		for i := 0; i < typ.NumField(); i++ {
			field := typ.Field(i)
			if !field.Type.Implements(colorType) {
				continue
			}
			if v.Field(i).IsNil() {
				t.Errorf("theme %q: field %s is nil", name, field.Name)
			}
		}
	}
}

func TestThemesMapKeyMatchesThemeName(t *testing.T) {
	for key, th := range Themes {
		if key != th.Name {
			t.Errorf("Themes[%q].Name = %q, want the map key", key, th.Name)
		}
	}
}
