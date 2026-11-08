/* Screen-reader semantics through Windows UI Automation.
 *
 * CUI draws every control itself and its Win32 backend answers no
 * WM_GETOBJECT, so assistive technology saw one empty window. This provider
 * publishes, after each frame, the controls a person can reach: every node
 * CUI hit-tests (buttons, fields, tabs, rows, menu items), with a name (the
 * control's text, or the label Kest registered for icon-only buttons and
 * fields), a control type, its screen rectangle, keyboard focus, and the
 * current text of fields. Focus changes raise the focus event screen readers
 * announce.
 *
 * Nothing runs until a UI Automation client asks for the window, and the
 * per-frame work stops again once no client is listening.
 *
 * The provider is flat: one root (the window) with the reachable controls as
 * its children, in drawing order. UI Automation may call it from its own
 * threads, so the published list is guarded by a lock and every element is
 * looked up by its stable CUI id. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <ole2.h>
#include <uiautomation.h>
#include <string.h>
#include "host.h"
#include "cui_internal.h"

#ifndef UIA_E_ELEMENTNOTAVAILABLE
#define UIA_E_ELEMENTNOTAVAILABLE ((HRESULT)0x80040201L)
#endif

enum { MAX_ITEMS = 1024, MAX_LABELS = 512, NAME_CAP = 160, VALUE_CAP = 512, LOOKUP = 4096 };

typedef struct {
    cui_id id;
    int role;
    char name[NAME_CAP];
    char help[NAME_CAP];
    char value[VALUE_CAP];
    bool has_value, focusable, selected;
    RECT screen;
} a11y_item;

typedef struct {
    cui_id id;
    int role;
    char name[NAME_CAP];
    char help[NAME_CAP];
    char value[VALUE_CAP];
    bool has_value, selected;
} a11y_label;

/* UI thread only: labels registered while this frame is built. */
static a11y_label labels[MAX_LABELS];
static int label_count;   /* cleared after each frame is published */

/* Published list, read by UI Automation threads under the lock. */
static SRWLOCK lock = SRWLOCK_INIT;
static a11y_item items[MAX_ITEMS];
static int item_count;
static cui_id focus_id;
static a11y_item building[MAX_ITEMS];

static HWND hwnd;
static cui_ctx *context;
static volatile LONG active;
static cui_id announced;

/* ------------------------------------------------------------------ */
/* Labels from Kest's widget wrappers                                  */

static void copy_label(char *dst, const char *src) {
    if (!src) { dst[0] = 0; return; }
    size_t n = 0;
    /* "Label###identity" and "Label##salt" name only "Label". */
    while (src[n] && n + 1 < NAME_CAP && !(src[n] == '#' && src[n + 1] == '#')) n++;
    memcpy(dst, src, n);
    dst[n] = 0;
}

static a11y_label *label_slot(cui_ctx *ui, cui_id id) {
    (void)ui;
    if (!active || !id) return NULL;
    for (int i = label_count - 1; i >= 0; i--) if (labels[i].id == id) return &labels[i];
    if (label_count >= MAX_LABELS) return NULL;
    a11y_label *l = &labels[label_count++];
    memset(l, 0, sizeof *l);
    l->id = id;
    return l;
}

void kest_a11y_label_id(cui_ctx *ui, cui_id id, int role, const char *name, const char *value) {
    a11y_label *l = label_slot(ui, id);
    if (!l) return;
    if (role) l->role = role;
    if (name && name[0]) copy_label(l->name, name);
    if (value) {
        size_t n = strlen(value);
        if (n >= VALUE_CAP) n = VALUE_CAP - 1;
        memcpy(l->value, value, n);
        l->value[n] = 0;
        l->has_value = true;
    }
}

/* The selected item of a composite (the tree's current row): while the
 * composite itself has keyboard focus, this item is reported as focused. */
void kest_a11y_selected(cui_ctx *ui, cui_id id) {
    a11y_label *l = label_slot(ui, id);
    if (l) l->selected = true;
}

/* The control just built: the last id CUI recorded for an item. */
void kest_a11y_label(cui_ctx *ui, int role, const char *name, const char *value) {
    kest_a11y_label_id(ui, ui->last_id, role, name, value);
}

/* Help text (a tooltip); it also names a control that shows no text. */
void kest_a11y_help_id(cui_ctx *ui, cui_id id, const char *text) {
    if (!text || !text[0]) return;
    a11y_label *l = label_slot(ui, id);
    if (l) copy_label(l->help, text);
}

void kest_tooltip(cui_ctx *ui, const char *text) {
    cui_tooltip(ui, text);
    kest_a11y_help_id(ui, ui->last_id, text);
}

static int control_type(int role, bool focusable) {
    switch (role) {
    case KEST_A11Y_BUTTON: return UIA_ButtonControlTypeId;
    case KEST_A11Y_EDIT: return UIA_EditControlTypeId;
    case KEST_A11Y_TAB: return UIA_TabItemControlTypeId;
    case KEST_A11Y_TREE_ITEM: return UIA_TreeItemControlTypeId;
    case KEST_A11Y_MENU_BUTTON: return UIA_SplitButtonControlTypeId;
    case KEST_A11Y_MENU_ITEM: return UIA_MenuItemControlTypeId;
    case KEST_A11Y_TREE: return UIA_TreeControlTypeId;
    default: return focusable ? UIA_ButtonControlTypeId : UIA_ListItemControlTypeId;
    }
}

/* ------------------------------------------------------------------ */
/* Publishing after each frame                                         */

/* Icon glyphs are Lucide private-use characters (U+E000..U+F8FF); a screen
 * reader would spell them as unknown symbols. */
static size_t glyph_length(const unsigned char *t, size_t left) {
    if (left >= 3 && (t[0] == 0xEE || (t[0] == 0xEF && t[1] < 0xA4))) return 3;
    return 0;
}

static void gather_text(cui_ctx *ui, int index, char *out, size_t *len, int depth) {
    if (index < 0 || index >= ui->node_count || depth > 24 || *len + 1 >= NAME_CAP) return;
    cui_node *n = &ui->nodes[index];
    /* Interactive descendants are published (and named) on their own. */
    if (depth > 0 && n->id && (n->flags & (CUI_NF_INTERACTIVE | CUI_NF_FOCUSABLE))) return;
    if (n->text && n->text_len > 0 && n->font != CUI_FONT_ICONS) {
        const unsigned char *t = (const unsigned char *)n->text;
        size_t total = (size_t)n->text_len, start = *len;
        bool spaced = *len == 0;
        for (size_t at = 0; at < total && *len + 1 < NAME_CAP;) {
            size_t skip = glyph_length(t + at, total - at);
            if (skip) { at += skip; continue; }
            if (!spaced) { out[(*len)++] = ' '; spaced = true; if (*len + 1 >= NAME_CAP) break; }
            out[(*len)++] = (char)t[at++];
        }
        /* Trim what glyph removal left at either end. */
        while (*len > start && out[*len - 1] == ' ') (*len)--;
        out[*len] = 0;
        size_t lead = 0;
        while (*len > 0 && out[lead] == ' ') lead++;
        if (lead) { memmove(out, out + lead, *len - lead + 1); *len -= lead; }
    }
    for (int c = n->first; c >= 0 && c < ui->node_count; c = ui->nodes[c].next)
        gather_text(ui, c, out, len, depth + 1);
}

static const a11y_label *find_label(cui_id id) {
    for (int i = label_count - 1; i >= 0; i--) if (labels[i].id == id) return &labels[i];
    return NULL;
}

static void publish(cui_ctx *ui) {
    /* Final, clipped hit rectangles of this frame, by id. */
    static int slots[LOOKUP];
    for (int i = 0; i < LOOKUP; i++) slots[i] = -1;
    for (int i = 0; i < ui->hit_count; i++) {
        cui_hit *h = &ui->hits[i];
        if (!h->id || !(h->flags & CUI_NF_INTERACTIVE) || (h->flags & CUI_NF_SCROLLBAR)) continue;
        if (h->rect.w < 1 || h->rect.h < 1) continue;
        unsigned k = (unsigned)h->id & (LOOKUP - 1);
        for (int probe = 0; probe < LOOKUP; probe++, k = (k + 1) & (LOOKUP - 1)) {
            if (slots[k] < 0) { slots[k] = i; break; }
            if (ui->hits[slots[k]].id == h->id) { slots[k] = i; break; }   /* the topmost wins */
        }
    }
    float s = cui_dpi_scale(ui);
    POINT origin = {0, 0};
    ClientToScreen(hwnd, &origin);
    int count = 0;
    for (int i = 0; i < ui->node_count && count < MAX_ITEMS; i++) {
        cui_node *n = &ui->nodes[i];
        if (!n->id || !(n->flags & (CUI_NF_INTERACTIVE | CUI_NF_FOCUSABLE)) || (n->flags & CUI_NF_SCROLLBAR)) continue;
        int hit = -1;
        unsigned k = (unsigned)n->id & (LOOKUP - 1);
        for (int probe = 0; probe < LOOKUP && slots[k] >= 0; probe++, k = (k + 1) & (LOOKUP - 1))
            if (ui->hits[slots[k]].id == n->id) { hit = slots[k]; break; }
        if (hit < 0) continue;   /* not on screen this frame */
        bool seen = false;
        for (int j = 0; j < count && !seen; j++) seen = building[j].id == n->id;
        if (seen) continue;
        a11y_item *it = &building[count];
        memset(it, 0, sizeof *it);
        it->id = n->id;
        it->focusable = (n->flags & CUI_NF_FOCUSABLE) != 0;
        const a11y_label *l = find_label(n->id);
        if (l && l->name[0]) memcpy(it->name, l->name, NAME_CAP);
        else { size_t len = 0; gather_text(ui, i, it->name, &len, 0); }
        if (!it->name[0] && l && l->help[0]) memcpy(it->name, l->help, NAME_CAP);
        if (l && l->help[0] && strcmp(l->help, it->name) != 0) memcpy(it->help, l->help, NAME_CAP);
        if (l && l->has_value) { memcpy(it->value, l->value, VALUE_CAP); it->has_value = true; }
        it->selected = l && l->selected;
        /* Unnamed, unfocusable hit areas (splitters, backdrops) say nothing. */
        if (!it->name[0] && !it->focusable && !it->has_value) continue;
        it->role = control_type(l ? l->role : 0, it->focusable);
        cui_rect r = ui->hits[hit].rect;
        it->screen = (RECT){ origin.x + (LONG)(r.x * s), origin.y + (LONG)(r.y * s),
                             origin.x + (LONG)((r.x + r.w) * s), origin.y + (LONG)((r.y + r.h) * s) };
        count++;
    }
    /* A focused composite (the collection tree) reports its selected item. */
    cui_id focus = ui->focus;
    const a11y_label *fl = focus ? find_label(focus) : NULL;
    if (fl && fl->role == KEST_A11Y_TREE)
        for (int j = 0; j < count; j++) if (building[j].selected) { focus = building[j].id; break; }
    AcquireSRWLockExclusive(&lock);
    memcpy(items, building, sizeof(a11y_item) * (size_t)count);
    item_count = count;
    focus_id = focus;
    ReleaseSRWLockExclusive(&lock);
}

static IRawElementProviderSimple *element_for(cui_id id);

void kest_a11y_frame(cui_ctx *ui, void *window) {
    context = ui;
    hwnd = (HWND)window;
    if (!active) { label_count = 0; return; }
    if (!UiaClientsAreListening()) {
        InterlockedExchange(&active, 0);
        announced = 0;
        label_count = 0;
        return;
    }
    publish(ui);
    label_count = 0;
    AcquireSRWLockShared(&lock);
    cui_id focus = focus_id;
    ReleaseSRWLockShared(&lock);
    if (focus && focus != announced) {
        announced = focus;
        IRawElementProviderSimple *e = element_for(focus);
        if (e) {
            UiaRaiseAutomationEvent(e, UIA_AutomationFocusChangedEventId);
            IRawElementProviderSimple_Release(e);
        }
    }
}

/* ------------------------------------------------------------------ */
/* COM objects                                                         */

typedef struct a11y_node {
    IRawElementProviderSimple simple;
    IRawElementProviderFragment fragment;
    IRawElementProviderFragmentRoot root;
    IValueProvider value;
    LONG refs;
    cui_id id;   /* 0: the window */
} a11y_node;

#define NODE_OF(ptr, member) ((a11y_node *)((char *)(ptr) - offsetof(a11y_node, member)))

static a11y_node root_node;

/* Under the shared lock. */
static int index_of(cui_id id) {
    for (int i = 0; i < item_count; i++) if (items[i].id == id) return i;
    return -1;
}

static HRESULT node_query(a11y_node *n, REFIID riid, void **out) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IRawElementProviderSimple)) *out = &n->simple;
    else if (IsEqualIID(riid, &IID_IRawElementProviderFragment)) *out = &n->fragment;
    else if (IsEqualIID(riid, &IID_IRawElementProviderFragmentRoot) && n->id == 0) *out = &n->root;
    else if (IsEqualIID(riid, &IID_IValueProvider) && n->id != 0) *out = &n->value;
    if (!*out) return E_NOINTERFACE;
    IRawElementProviderSimple_AddRef(&n->simple);
    return S_OK;
}
static ULONG node_addref(a11y_node *n) {
    if (n == &root_node) return 2;
    return (ULONG)InterlockedIncrement(&n->refs);
}
static ULONG node_release(a11y_node *n) {
    if (n == &root_node) return 1;
    LONG r = InterlockedDecrement(&n->refs);
    if (r == 0) CoTaskMemFree(n);
    return (ULONG)r;
}

static BSTR utf8_bstr(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return SysAllocString(L"");
    BSTR b = SysAllocStringLen(NULL, (UINT)(n - 1));
    if (b) MultiByteToWideChar(CP_UTF8, 0, s, -1, b, n);
    return b;
}

/* IRawElementProviderSimple */
static HRESULT STDMETHODCALLTYPE s_query(IRawElementProviderSimple *t, REFIID r, void **o) { return node_query(NODE_OF(t, simple), r, o); }
static ULONG STDMETHODCALLTYPE s_addref(IRawElementProviderSimple *t) { return node_addref(NODE_OF(t, simple)); }
static ULONG STDMETHODCALLTYPE s_release(IRawElementProviderSimple *t) { return node_release(NODE_OF(t, simple)); }
static HRESULT STDMETHODCALLTYPE s_options(IRawElementProviderSimple *t, enum ProviderOptions *o) {
    (void)t;
    *o = ProviderOptions_ServerSideProvider;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE s_pattern(IRawElementProviderSimple *t, PATTERNID pattern, IUnknown **out) {
    a11y_node *n = NODE_OF(t, simple);
    *out = NULL;
    if (pattern != UIA_ValuePatternId || n->id == 0) return S_OK;
    AcquireSRWLockShared(&lock);
    int i = index_of(n->id);
    bool has = i >= 0 && items[i].has_value;
    ReleaseSRWLockShared(&lock);
    if (has) { *out = (IUnknown *)&n->value; node_addref(n); }
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE s_property(IRawElementProviderSimple *t, PROPERTYID property, VARIANT *v) {
    a11y_node *n = NODE_OF(t, simple);
    VariantInit(v);
    if (n->id == 0) {
        if (property == UIA_NamePropertyId) { v->vt = VT_BSTR; v->bstrVal = SysAllocString(L"Kest"); }
        else if (property == UIA_FrameworkIdPropertyId) { v->vt = VT_BSTR; v->bstrVal = SysAllocString(L"CUI"); }
        return S_OK;
    }
    AcquireSRWLockShared(&lock);
    int i = index_of(n->id);
    if (i < 0) { ReleaseSRWLockShared(&lock); return UIA_E_ELEMENTNOTAVAILABLE; }
    a11y_item it = items[i];
    cui_id focus = focus_id;
    ReleaseSRWLockShared(&lock);
    switch (property) {
    case UIA_NamePropertyId: v->vt = VT_BSTR; v->bstrVal = utf8_bstr(it.name); break;
    case UIA_HelpTextPropertyId: if (it.help[0]) { v->vt = VT_BSTR; v->bstrVal = utf8_bstr(it.help); } break;
    case UIA_ControlTypePropertyId: v->vt = VT_I4; v->lVal = it.role; break;
    case UIA_AutomationIdPropertyId: {
        wchar_t buf[16];
        wsprintfW(buf, L"%08X", (unsigned)it.id);
        v->vt = VT_BSTR; v->bstrVal = SysAllocString(buf);
        break;
    }
    case UIA_IsKeyboardFocusablePropertyId: v->vt = VT_BOOL; v->boolVal = it.focusable ? VARIANT_TRUE : VARIANT_FALSE; break;
    case UIA_HasKeyboardFocusPropertyId: v->vt = VT_BOOL; v->boolVal = focus == it.id ? VARIANT_TRUE : VARIANT_FALSE; break;
    case UIA_IsEnabledPropertyId: case UIA_IsControlElementPropertyId: case UIA_IsContentElementPropertyId:
        v->vt = VT_BOOL; v->boolVal = VARIANT_TRUE; break;
    case UIA_FrameworkIdPropertyId: v->vt = VT_BSTR; v->bstrVal = SysAllocString(L"CUI"); break;
    default: break;
    }
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE s_host(IRawElementProviderSimple *t, IRawElementProviderSimple **out) {
    a11y_node *n = NODE_OF(t, simple);
    *out = NULL;
    if (n->id == 0 && hwnd) return UiaHostProviderFromHwnd(hwnd, out);
    return S_OK;
}
static IRawElementProviderSimpleVtbl simple_vtbl = { s_query, s_addref, s_release, s_options, s_pattern, s_property, s_host };

/* IRawElementProviderFragment */
static IRawElementProviderFragment *new_fragment(cui_id id);
static HRESULT STDMETHODCALLTYPE f_query(IRawElementProviderFragment *t, REFIID r, void **o) { return node_query(NODE_OF(t, fragment), r, o); }
static ULONG STDMETHODCALLTYPE f_addref(IRawElementProviderFragment *t) { return node_addref(NODE_OF(t, fragment)); }
static ULONG STDMETHODCALLTYPE f_release(IRawElementProviderFragment *t) { return node_release(NODE_OF(t, fragment)); }
static HRESULT STDMETHODCALLTYPE f_navigate(IRawElementProviderFragment *t, enum NavigateDirection d, IRawElementProviderFragment **out) {
    a11y_node *n = NODE_OF(t, fragment);
    *out = NULL;
    cui_id target = 0;
    bool to_root = false;
    AcquireSRWLockShared(&lock);
    if (n->id == 0) {
        if (d == NavigateDirection_FirstChild && item_count > 0) target = items[0].id;
        if (d == NavigateDirection_LastChild && item_count > 0) target = items[item_count - 1].id;
    } else {
        int i = index_of(n->id);
        if (i < 0) { ReleaseSRWLockShared(&lock); return UIA_E_ELEMENTNOTAVAILABLE; }
        if (d == NavigateDirection_Parent) to_root = true;
        if (d == NavigateDirection_NextSibling && i + 1 < item_count) target = items[i + 1].id;
        if (d == NavigateDirection_PreviousSibling && i > 0) target = items[i - 1].id;
    }
    ReleaseSRWLockShared(&lock);
    if (to_root) { *out = &root_node.fragment; return S_OK; }
    if (target) *out = new_fragment(target);
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE f_runtime(IRawElementProviderFragment *t, SAFEARRAY **out) {
    a11y_node *n = NODE_OF(t, fragment);
    *out = NULL;
    if (n->id == 0) return S_OK;   /* the window's id comes from its host */
    SAFEARRAY *a = SafeArrayCreateVector(VT_I4, 0, 2);
    if (!a) return E_OUTOFMEMORY;
    LONG at = 0, value = UiaAppendRuntimeId;
    SafeArrayPutElement(a, &at, &value);
    at = 1; value = (LONG)n->id;
    SafeArrayPutElement(a, &at, &value);
    *out = a;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE f_bounds(IRawElementProviderFragment *t, struct UiaRect *out) {
    a11y_node *n = NODE_OF(t, fragment);
    memset(out, 0, sizeof *out);
    if (n->id == 0) return S_OK;
    AcquireSRWLockShared(&lock);
    int i = index_of(n->id);
    RECT r = i >= 0 ? items[i].screen : (RECT){0};
    ReleaseSRWLockShared(&lock);
    if (i < 0) return UIA_E_ELEMENTNOTAVAILABLE;
    out->left = r.left; out->top = r.top; out->width = r.right - r.left; out->height = r.bottom - r.top;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE f_embedded(IRawElementProviderFragment *t, SAFEARRAY **out) { (void)t; *out = NULL; return S_OK; }
static HRESULT STDMETHODCALLTYPE f_focus(IRawElementProviderFragment *t) { (void)t; return S_OK; }
static HRESULT STDMETHODCALLTYPE f_root(IRawElementProviderFragment *t, IRawElementProviderFragmentRoot **out) {
    (void)t;
    *out = &root_node.root;
    return S_OK;
}
static IRawElementProviderFragmentVtbl fragment_vtbl = { f_query, f_addref, f_release, f_navigate, f_runtime, f_bounds, f_embedded, f_focus, f_root };

/* IRawElementProviderFragmentRoot (the window only) */
static HRESULT STDMETHODCALLTYPE r_query(IRawElementProviderFragmentRoot *t, REFIID r, void **o) { return node_query(NODE_OF(t, root), r, o); }
static ULONG STDMETHODCALLTYPE r_addref(IRawElementProviderFragmentRoot *t) { return node_addref(NODE_OF(t, root)); }
static ULONG STDMETHODCALLTYPE r_release(IRawElementProviderFragmentRoot *t) { return node_release(NODE_OF(t, root)); }
static HRESULT STDMETHODCALLTYPE r_point(IRawElementProviderFragmentRoot *t, double x, double y, IRawElementProviderFragment **out) {
    (void)t;
    *out = NULL;
    cui_id found = 0;
    AcquireSRWLockShared(&lock);
    for (int i = item_count - 1; i >= 0 && !found; i--) {
        RECT r = items[i].screen;
        if (x >= r.left && x < r.right && y >= r.top && y < r.bottom) found = items[i].id;
    }
    ReleaseSRWLockShared(&lock);
    if (found) *out = new_fragment(found);
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE r_focus(IRawElementProviderFragmentRoot *t, IRawElementProviderFragment **out) {
    (void)t;
    *out = NULL;
    AcquireSRWLockShared(&lock);
    cui_id id = index_of(focus_id) >= 0 ? focus_id : 0;
    ReleaseSRWLockShared(&lock);
    if (id) *out = new_fragment(id);
    return S_OK;
}
static IRawElementProviderFragmentRootVtbl root_vtbl = { r_query, r_addref, r_release, r_point, r_focus };

/* IValueProvider (fields): the text, editable with the keyboard. */
static HRESULT STDMETHODCALLTYPE v_query(IValueProvider *t, REFIID r, void **o) { return node_query(NODE_OF(t, value), r, o); }
static ULONG STDMETHODCALLTYPE v_addref(IValueProvider *t) { return node_addref(NODE_OF(t, value)); }
static ULONG STDMETHODCALLTYPE v_release(IValueProvider *t) { return node_release(NODE_OF(t, value)); }
static HRESULT STDMETHODCALLTYPE v_set(IValueProvider *t, LPCWSTR text) { (void)t; (void)text; return E_NOTIMPL; }
static HRESULT STDMETHODCALLTYPE v_get(IValueProvider *t, BSTR *out) {
    a11y_node *n = NODE_OF(t, value);
    *out = NULL;
    AcquireSRWLockShared(&lock);
    int i = index_of(n->id);
    char text[VALUE_CAP];
    if (i >= 0) memcpy(text, items[i].value, VALUE_CAP);
    ReleaseSRWLockShared(&lock);
    if (i < 0) return UIA_E_ELEMENTNOTAVAILABLE;
    *out = utf8_bstr(text);
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE v_readonly(IValueProvider *t, BOOL *out) { (void)t; *out = FALSE; return S_OK; }
static IValueProviderVtbl value_vtbl = { v_query, v_addref, v_release, v_set, v_get, v_readonly };

static a11y_node *new_node(cui_id id) {
    a11y_node *n = CoTaskMemAlloc(sizeof *n);
    if (!n) return NULL;
    n->simple.lpVtbl = &simple_vtbl;
    n->fragment.lpVtbl = &fragment_vtbl;
    n->root.lpVtbl = &root_vtbl;
    n->value.lpVtbl = &value_vtbl;
    n->refs = 1;
    n->id = id;
    return n;
}
static IRawElementProviderFragment *new_fragment(cui_id id) {
    a11y_node *n = new_node(id);
    return n ? &n->fragment : NULL;
}
static IRawElementProviderSimple *element_for(cui_id id) {
    AcquireSRWLockShared(&lock);
    bool known = index_of(id) >= 0;
    ReleaseSRWLockShared(&lock);
    if (!known) return NULL;
    a11y_node *n = new_node(id);
    return n ? &n->simple : NULL;
}

/* WM_GETOBJECT from the window procedure. */
bool kest_a11y_get_object(void *window, uintptr_t wp, intptr_t lp, intptr_t *result) {
    if ((LONG)lp != UiaRootObjectId) return false;
    hwnd = (HWND)window;
    if (!root_node.simple.lpVtbl) {
        root_node.simple.lpVtbl = &simple_vtbl;
        root_node.fragment.lpVtbl = &fragment_vtbl;
        root_node.root.lpVtbl = &root_vtbl;
        root_node.value.lpVtbl = &value_vtbl;
        root_node.refs = 1;
        root_node.id = 0;
    }
    if (InterlockedExchange(&active, 1) == 0 && context) {
        /* Publish what the last frame drew now, and draw again so the labels
         * Kest registers (skipped while nobody listened) are included. */
        publish(context);
        cui_request_redraw(context);
        kest_host_wake();
    }
    *result = (intptr_t)UiaReturnRawElementProvider((HWND)window, (WPARAM)wp, (LPARAM)lp, &root_node.simple);
    return true;
}
