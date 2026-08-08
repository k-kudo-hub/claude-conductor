package zellij

import "testing"

func TestParseTabs(t *testing.T) {
	// `zellij action list-tabs` の出力。1 行目はヘッダー。
	out := `ID POSITION NAME
1 0 Main
2 1 api-feature
3 2 web-fix
`

	got := ParseTabs(out)
	want := []Tab{
		{ID: "1", Name: "Main"},
		{ID: "2", Name: "api-feature"},
		{ID: "3", Name: "web-fix"},
	}

	if len(got) != len(want) {
		t.Fatalf("ParseTabs returned %d tabs, want %d: %+v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("tab %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

// タブ名に空白が入っても最後まで名前として扱う。bash 版の表示順取得は
// awk '{print $3}' で 3 列目しか見ておらず、空白入りの名前が切れていた。
func TestParseTabsKeepsSpacesInNames(t *testing.T) {
	out := `ID POSITION NAME
1 0 Main
2 1 my long tab name
`

	got := ParseTabs(out)
	if len(got) != 2 {
		t.Fatalf("ParseTabs returned %d tabs, want 2", len(got))
	}
	if got[1].Name != "my long tab name" {
		t.Errorf("Name = %q, want %q", got[1].Name, "my long tab name")
	}
}

func TestParseTabsEmptyOutput(t *testing.T) {
	for _, out := range []string{"", "\n", "ID POSITION NAME\n"} {
		if got := ParseTabs(out); len(got) != 0 {
			t.Errorf("ParseTabs(%q) returned %d tabs, want 0", out, len(got))
		}
	}
}

// 列が足りない行は読み飛ばす。壊れた 1 行で一覧を落とさない。
func TestParseTabsSkipsShortLines(t *testing.T) {
	out := `ID POSITION NAME
1 0 Main
broken
2 1 api-feature
`

	got := ParseTabs(out)
	if len(got) != 2 {
		t.Fatalf("ParseTabs returned %d tabs, want 2: %+v", len(got), got)
	}
	if got[1].Name != "api-feature" {
		t.Errorf("Name = %q, want api-feature", got[1].Name)
	}
}

func TestTabsFindByName(t *testing.T) {
	tabs := []Tab{
		{ID: "1", Name: "Main"},
		{ID: "2", Name: "api-feature"},
	}

	if got := FindByName(tabs, "api-feature"); got == nil || got.ID != "2" {
		t.Errorf("FindByName returned %v, want the tab with ID 2", got)
	}
	if got := FindByName(tabs, "no-such-tab"); got != nil {
		t.Errorf("FindByName returned %v for a missing name, want nil", got)
	}
}

func TestTabNames(t *testing.T) {
	tabs := []Tab{
		{ID: "1", Name: "Main"},
		{ID: "2", Name: "api-feature"},
	}

	got := Names(tabs)
	if len(got) != 2 || got[0] != "Main" || got[1] != "api-feature" {
		t.Errorf("Names = %v, want [Main api-feature]", got)
	}
}
