// BentoOverlay — detail screens that sit over a dimmed workspace.
// Three variants: 'palette' (⌘K command palette), 'ripgrep' (project search),
// 'resurrect' (project launcher / session resurrection).

const { useState: useState_OV } = React;

// ─── Shared dimmed-workspace backdrop ────────────────────────
function DimmedBackdrop({ theme, dim = 0.55 }) {
  return (
    <div style={{ position: 'absolute', inset: 0 }}>
      <BentoWorkspace theme={theme} />
      <div style={{
        position: 'absolute', inset: 0,
        background: `rgba(0,0,0,${dim})`,
        backdropFilter: 'blur(3px)',
        WebkitBackdropFilter: 'blur(3px)',
        borderRadius: theme.windowRadius,
      }} />
    </div>
  );
}

// ─── Command palette ─────────────────────────────────────────
const PALETTE_GROUPS = [
  { label: 'Pane', items: [
    { glyph: '⊞', name: 'Split pane right', shortcut: ['⌘', 'D'], desc: 'inherit cwd' },
    { glyph: '⊟', name: 'Split pane down', shortcut: ['⌘', '⇧', 'D'], desc: 'inherit cwd' },
    { glyph: '⇄', name: 'Flip pane: terminal ⇄ editor', shortcut: ['⌘', '⏎'], desc: 'same buffer', active: true },
    { glyph: '⤢', name: 'Zoom active pane', shortcut: ['⌘', '/'], desc: 'temporary focus' },
    { glyph: '✕', name: 'Close active pane', shortcut: ['⌘', 'W'] },
  ]},
  { label: 'Layout', items: [
    { glyph: '▦', name: 'Apply layout: 2 × 2 grid', shortcut: ['⌘', '2'] },
    { glyph: '◫', name: 'Apply layout: editor + drawer', shortcut: ['⌘', '3'] },
    { glyph: '⎕', name: 'Save layout as preset…' },
  ]},
  { label: 'Project', items: [
    { glyph: '⏎', name: 'Open project…', shortcut: ['⌘', 'O'] },
    { glyph: '↻', name: 'Restore last session', desc: 'PaneView.swift, registry.rs, 2 terminals' },
  ]},
];

function PaletteRow({ item, theme, active }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '8px 16px', cursor: 'pointer',
      background: active ? theme.accentSoft : 'transparent',
      borderLeft: active ? `2px solid ${theme.borderActive}` : '2px solid transparent',
      marginLeft: -2,
    }}>
      <span style={{
        fontFamily: theme.font, fontSize: 14, color: active ? theme.text : theme.dim,
        width: 18, textAlign: 'center', flexShrink: 0,
      }}>{item.glyph}</span>
      <span style={{
        fontFamily: theme.uiFont, fontSize: 13, color: active ? theme.text : theme.text,
        fontWeight: active ? 500 : 400, flex: 1,
      }}>{item.name}</span>
      {item.desc && (
        <span style={{
          fontFamily: theme.font, fontSize: 11, color: theme.dim,
        }}>{item.desc}</span>
      )}
      {item.shortcut && (
        <div style={{ display: 'flex', gap: 2 }}>
          {item.shortcut.map((k, i) => (
            <span key={i} style={{
              fontFamily: theme.font, fontSize: 10, color: theme.dim,
              background: theme.bg, padding: '2px 5px',
              borderRadius: 3, minWidth: 14, textAlign: 'center',
              border: `0.5px solid ${theme.border}`,
            }}>{k}</span>
          ))}
        </div>
      )}
    </div>
  );
}

function CommandPalette({ theme }) {
  return (
    <div style={{
      position: 'absolute', top: 80, left: '50%', transform: 'translateX(-50%)',
      width: 640, background: theme.panel,
      borderRadius: 12, overflow: 'hidden',
      border: `1px solid ${theme.border}`,
      boxShadow: '0 32px 80px rgba(0,0,0,0.55), 0 0 0 0.5px rgba(255,255,255,0.05), inset 0 1px 0 rgba(255,255,255,0.04)',
    }}>
      {/* Input */}
      <div style={{
        height: 52, display: 'flex', alignItems: 'center', gap: 12,
        padding: '0 18px', borderBottom: `1px solid ${theme.border}`,
      }}>
        <svg width="14" height="14" viewBox="0 0 14 14">
          <circle cx="6" cy="6" r="4.2" stroke={theme.dim} strokeWidth="1.2" fill="none"/>
          <path d="M9.2 9.2 L12 12" stroke={theme.dim} strokeWidth="1.2" strokeLinecap="round"/>
        </svg>
        <span style={{
          fontFamily: theme.font, fontSize: 14, color: theme.text, flex: 1,
        }}>flip<span style={{
          display: 'inline-block', width: 7, height: 16, verticalAlign: 'middle',
          background: theme.cursor, marginLeft: 1, marginBottom: -3,
        }} /></span>
        <span style={{
          fontFamily: theme.font, fontSize: 11, color: theme.dim,
        }}>3 matches</span>
      </div>

      {/* Results */}
      <div style={{ maxHeight: 480, overflow: 'hidden', padding: '6px 0 8px' }}>
        {PALETTE_GROUPS.map((g, gi) => (
          <div key={gi}>
            <div style={{
              padding: '10px 16px 4px',
              fontFamily: theme.font, fontSize: 10, fontWeight: 600,
              color: theme.dim, letterSpacing: 1.2,
            }}>{g.label.toUpperCase()}</div>
            {g.items.map((item, i) => (
              <PaletteRow key={i} item={item} theme={theme} active={item.active} />
            ))}
          </div>
        ))}
      </div>

      {/* Footer */}
      <div style={{
        height: 30, display: 'flex', alignItems: 'center', gap: 14,
        padding: '0 16px', background: theme.chrome,
        borderTop: `1px solid ${theme.border}`,
        fontFamily: theme.font, fontSize: 10, color: theme.dim,
      }}>
        <span>↑↓ navigate</span>
        <span>⏎ run</span>
        <span>⌘⏎ run in new pane</span>
        <span style={{ marginLeft: 'auto' }}>esc close</span>
      </div>
    </div>
  );
}

// ─── Ripgrep search ──────────────────────────────────────────
const RG_RESULTS = [
  { file: 'Sources/Bento/Panes/PaneGrid.swift', matches: [
    { ln: 42, before: '        guard let active = active else { return }', match: 'split', after: null,
      segs: [
        { v: '        ' },
        { t: 'kw', v: 'guard let' }, { v: ' active = active ' },
        { t: 'kw', v: 'else' }, { v: ' { ' }, { t: 'kw', v: 'return' }, { v: ' }' },
      ]},
    { ln: 58, segs: [
      { v: '        ' },
      { t: 'kw', v: 'let' }, { v: ' child = active.' },
      { t: 'hit', v: 'split' }, { v: '(' }, { t: 'kw', v: 'inheriting' }, { v: ': cwd, ' },
      { t: 'kw', v: 'direction' }, { v: ': dir)' },
    ]},
    { ln: 60, segs: [
      { v: '        registry.' },
      { t: 'hit', v: 'split' }, { v: '(parent: active.id, child: child.id, dir: dir)' },
    ]},
  ]},
  { file: 'crates/bento-core/src/registry.rs', matches: [
    { ln: 24, segs: [
      { v: '    ' },
      { t: 'kw', v: 'pub async fn' }, { v: ' ' },
      { t: 'hit', v: 'split' }, { v: '(' },
      { t: 'punc', v: '&mut' }, { v: ' ' }, { t: 'kw', v: 'self' }, { v: ', id: ' },
      { t: 'ty', v: 'PaneId' }, { v: ', dir: ' }, { t: 'ty', v: 'Direction' }, { v: ')' },
    ]},
    { ln: 31, segs: [
      { v: '        ' }, { t: 'kw', v: 'self' }, { v: '.tx.' },
      { t: 'fn', v: 'send' }, { v: '(' }, { t: 'ty', v: 'PaneEvent' }, { t: 'punc', v: '::' },
      { t: 'ty', v: 'Split' }, { v: ' { parent, child, dir })' },
    ]},
  ]},
  { file: 'crates/bento-core/src/split.rs', matches: [
    { ln: 8, segs: [
      { t: 'kw', v: 'pub fn' }, { v: ' ' }, { t: 'hit', v: 'split' }, { v: '_inheriting(' },
      { t: 'punc', v: '&' }, { t: 'kw', v: 'self' }, { v: ', dir: ' }, { t: 'ty', v: 'Direction' }, { v: ') -> ' },
      { t: 'ty', v: 'Pane' }, { v: ' {' },
    ]},
  ]},
];

function RipgrepPanel({ theme }) {
  return (
    <div style={{
      position: 'absolute', top: 80, left: '50%', transform: 'translateX(-50%)',
      width: 880, maxHeight: 700, background: theme.panel,
      borderRadius: 12, overflow: 'hidden',
      border: `1px solid ${theme.border}`,
      boxShadow: '0 32px 80px rgba(15,15,30,0.6), 0 0 0 0.5px rgba(187,154,247,0.18), 0 0 60px rgba(187,154,247,0.10)',
      display: 'flex', flexDirection: 'column',
    }}>
      {/* Input row */}
      <div style={{
        padding: 14, display: 'flex', alignItems: 'center', gap: 10,
        borderBottom: `1px solid ${theme.border}`,
      }}>
        <span style={{
          fontFamily: theme.font, fontSize: 10, fontWeight: 600, color: theme.borderActive,
          letterSpacing: 1.2,
        }}>RG</span>
        <div style={{
          flex: 1, height: 36, display: 'flex', alignItems: 'center',
          padding: '0 12px', gap: 10, background: theme.bg,
          borderRadius: 8, border: `1px solid ${theme.borderActive}`,
          boxShadow: `0 0 0 3px ${theme.accentSoft}`,
        }}>
          <span style={{
            fontFamily: theme.font, fontSize: 14, color: theme.text, flex: 1,
          }}>split<span style={{
            display: 'inline-block', width: 7, height: 16, verticalAlign: 'middle',
            background: theme.cursor, marginLeft: 1, marginBottom: -3,
          }} /></span>
          <span style={{ fontFamily: theme.font, fontSize: 11, color: theme.dim }}>
            <span style={{ color: theme.borderActive, fontWeight: 600 }}>4</span> hits ·{' '}
            <span style={{ color: theme.borderActive, fontWeight: 600 }}>3</span> files · 12 ms
          </span>
        </div>
        {/* Filter toggles */}
        <div style={{ display: 'flex', gap: 4 }}>
          {['Aa', '.*', '⊕'].map((g, i) => (
            <span key={i} style={{
              fontFamily: theme.font, fontSize: 11, color: i === 0 ? theme.borderActive : theme.dim,
              padding: '6px 8px', borderRadius: 5,
              background: i === 0 ? theme.accentSoft : 'transparent',
              border: `1px solid ${i === 0 ? theme.borderActive : theme.border}`,
              minWidth: 22, textAlign: 'center', cursor: 'pointer',
            }}>{g}</span>
          ))}
        </div>
      </div>

      {/* Include / scope */}
      <div style={{
        padding: '8px 16px', display: 'flex', alignItems: 'center', gap: 12,
        borderBottom: `1px solid ${theme.border}`,
        fontFamily: theme.font, fontSize: 11, color: theme.dim,
      }}>
        <span><span style={{ color: theme.veryDim }}>files</span> Sources/** crates/**</span>
        <span style={{ color: theme.veryDim }}>·</span>
        <span><span style={{ color: theme.veryDim }}>exclude</span> .build, target</span>
        <span style={{ marginLeft: 'auto', color: theme.borderActive, fontWeight: 600 }}>open all in new panes</span>
      </div>

      {/* Results */}
      <div style={{ flex: 1, overflow: 'hidden', padding: '6px 0' }}>
        {RG_RESULTS.map((r, ri) => (
          <div key={ri}>
            <div style={{
              padding: '10px 16px 6px', display: 'flex', alignItems: 'center', gap: 10,
              fontFamily: theme.font, fontSize: 12,
            }}>
              <svg width="9" height="9" viewBox="0 0 9 9">
                <path d="M3 2 L6 4.5 L3 7" stroke={theme.dim} strokeWidth="1" fill="none" strokeLinecap="round"/>
              </svg>
              <span style={{ color: theme.dim }}>{r.file.split('/').slice(0, -1).join('/')}/</span>
              <span style={{ color: theme.text, fontWeight: 500 }}>{r.file.split('/').pop()}</span>
              <span style={{
                marginLeft: 'auto', fontSize: 10, color: theme.dim,
                padding: '1px 6px', borderRadius: 3, background: theme.accentSoft,
              }}>{r.matches.length} match{r.matches.length > 1 ? 'es' : ''}</span>
            </div>
            {r.matches.map((m, mi) => (
              <div key={mi} style={{
                display: 'flex', padding: '3px 16px', cursor: 'pointer',
                fontFamily: theme.font, fontSize: 12, lineHeight: '18px',
              }}>
                <span style={{
                  width: 44, color: theme.veryDim, textAlign: 'right',
                  paddingRight: 12, flexShrink: 0,
                }}>{m.ln}</span>
                <span style={{ whiteSpace: 'pre', color: theme.text }}>
                  {m.segs.map((s, si) => {
                    if (s.t === 'hit') {
                      return <span key={si} style={{
                        background: theme.borderActive, color: theme.bg,
                        fontWeight: 600, borderRadius: 2, padding: '0 1px',
                      }}>{s.v}</span>;
                    }
                    const c = s.t ? theme.sx[s.t] : theme.text;
                    return <span key={si} style={{ color: c }}>{s.v}</span>;
                  })}
                </span>
              </div>
            ))}
          </div>
        ))}
      </div>

      {/* Footer */}
      <div style={{
        height: 30, display: 'flex', alignItems: 'center', gap: 14,
        padding: '0 16px', background: theme.chrome,
        borderTop: `1px solid ${theme.border}`,
        fontFamily: theme.font, fontSize: 10, color: theme.dim,
      }}>
        <span>↑↓ navigate</span>
        <span>⏎ open in active pane</span>
        <span>⌘⏎ open in new pane</span>
        <span>⌥⏎ peek</span>
        <span style={{ marginLeft: 'auto' }}>ripgrep · -i --hidden</span>
      </div>
    </div>
  );
}

// ─── Session resurrection / launcher ─────────────────────────
const RECENT_PROJECTS = [
  {
    name: 'bento', path: '~/code/bento', branch: 'main',
    panes: 4, layout: '2x2', last: 'today · 14:32',
    files: ['PaneView.swift', 'registry.rs'],
    terms: ['cargo run', 'cargo test'],
    pinned: true, active: true,
  },
  {
    name: 'ghostty-shaders', path: '~/code/ghostty-shaders', branch: 'metal-3',
    panes: 3, layout: 'editor+drawer', last: 'yesterday · 22:10',
    files: ['Renderer.swift'], terms: ['swift run', 'log stream'],
  },
  {
    name: 'sttextview-spike', path: '~/code/sttextview', branch: 'textkit-2',
    panes: 2, layout: '1x2', last: 'mar 12',
    files: ['SyntaxHighlighter.swift'], terms: ['swift test'],
  },
  {
    name: 'dotfiles', path: '~/.config', branch: 'main',
    panes: 1, layout: '1x1', last: 'mar 03',
    files: ['hammerspoon/init.lua'], terms: [],
  },
];

function LayoutPreview({ layout, theme }) {
  // Draw the pane layout as a tiny diagram.
  const g = 1;
  const cellStyle = {
    border: `1px solid ${theme.borderActive}`,
    borderRadius: 1,
    background: theme.accentSoft,
  };
  if (layout === '2x2') {
    return (
      <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gridTemplateRows: '1.2fr 1fr', gap: g, width: 56, height: 36 }}>
        <div style={{ ...cellStyle, background: theme.borderActive }} /><div style={cellStyle} />
        <div style={cellStyle} /><div style={cellStyle} />
      </div>
    );
  }
  if (layout === 'editor+drawer') {
    return (
      <div style={{ display: 'grid', gridTemplateColumns: '1fr', gridTemplateRows: '2fr 1fr', gap: g, width: 56, height: 36 }}>
        <div style={{ ...cellStyle, background: theme.borderActive }} />
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: g }}>
          <div style={cellStyle} /><div style={cellStyle} />
        </div>
      </div>
    );
  }
  if (layout === '1x2') {
    return (
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: g, width: 56, height: 36 }}>
        <div style={{ ...cellStyle, background: theme.borderActive }} /><div style={cellStyle} />
      </div>
    );
  }
  return <div style={{ ...cellStyle, width: 56, height: 36, background: theme.borderActive }} />;
}

function ProjectCard({ p, theme }) {
  return (
    <div style={{
      display: 'flex', gap: 16, alignItems: 'center',
      padding: '14px 18px', cursor: 'pointer',
      background: p.active ? theme.accentSoft : 'transparent',
      borderLeft: p.active ? `2px solid ${theme.borderActive}` : '2px solid transparent',
      marginLeft: -2,
      borderBottom: `1px solid ${theme.border}`,
    }}>
      <LayoutPreview layout={p.layout} theme={theme} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 4 }}>
          <span style={{
            fontFamily: theme.uiFont, fontSize: 15, fontWeight: 600, color: theme.text,
          }}>{p.name}</span>
          {p.pinned && (
            <svg width="9" height="9" viewBox="0 0 9 9" style={{ flexShrink: 0 }}>
              <path d="M4.5 1 L4.5 6 M2.5 6 L6.5 6 L4.5 8 Z" stroke={theme.borderActive} strokeWidth="1" fill={theme.borderActive}/>
            </svg>
          )}
          <span style={{ fontFamily: theme.font, fontSize: 11, color: theme.dim }}>{p.path}</span>
          <span style={{ marginLeft: 'auto', fontFamily: theme.font, fontSize: 11, color: theme.dim }}>{p.last}</span>
        </div>
        <div style={{ display: 'flex', gap: 14, fontFamily: theme.font, fontSize: 11, color: theme.dim }}>
          <span>
            <svg width="9" height="9" viewBox="0 0 9 9" style={{ display: 'inline-block', verticalAlign: -1, marginRight: 4 }}>
              <circle cx="2" cy="2" r="1.5" fill={theme.borderActive}/>
              <path d="M2 3 L2 7 M2 7 L6 7 L6 5" stroke={theme.borderActive} strokeWidth="1" fill="none"/>
              <circle cx="6" cy="5" r="1" fill="none" stroke={theme.borderActive} strokeWidth="1"/>
            </svg>
            {p.branch}
          </span>
          <span>{p.panes} panes</span>
          {p.files.length > 0 && (
            <span>
              <span style={{ color: theme.veryDim }}>open </span>
              {p.files.join(', ')}
            </span>
          )}
          {p.terms.length > 0 && (
            <span>
              <span style={{ color: theme.veryDim }}>running </span>
              {p.terms.map((t, i) => (
                <span key={i}>
                  <span style={{ color: theme.text }}>{t}</span>
                  {i < p.terms.length - 1 ? ', ' : ''}
                </span>
              ))}
            </span>
          )}
        </div>
      </div>
      {p.active && (
        <span style={{
          fontFamily: theme.font, fontSize: 10, fontWeight: 600,
          color: theme.bg, background: theme.borderActive,
          padding: '3px 8px', borderRadius: 3, letterSpacing: 0.5,
        }}>RESUME</span>
      )}
    </div>
  );
}

function ResurrectLauncher({ theme }) {
  return (
    <div style={{
      position: 'absolute', top: 70, left: '50%', transform: 'translateX(-50%)',
      width: 920, background: theme.panel,
      borderRadius: 12, overflow: 'hidden',
      border: `1px solid ${theme.border}`,
      boxShadow: '0 32px 80px rgba(0,0,0,0.7), 0 0 0 0.5px rgba(217,166,99,0.20), 0 0 60px rgba(217,166,99,0.08)',
      display: 'flex', flexDirection: 'column',
    }}>
      {/* header */}
      <div style={{
        padding: '20px 24px 16px', borderBottom: `1px solid ${theme.border}`,
        display: 'flex', alignItems: 'baseline', gap: 16,
      }}>
        <div style={{
          fontFamily: theme.uiFont, fontSize: 22, fontWeight: 700, color: theme.text,
          letterSpacing: -0.3,
        }}>Resume a project</div>
        <div style={{
          fontFamily: theme.font, fontSize: 12, color: theme.dim,
        }}>panes, cwd, open buffers, scroll position — all restored</div>
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 8 }}>
          <Kbd theme={theme} keys={['⌘', 'O']} />
          <span style={{ fontFamily: theme.font, fontSize: 11, color: theme.dim }}>new</span>
        </div>
      </div>

      {/* search */}
      <div style={{
        padding: '10px 24px', display: 'flex', alignItems: 'center', gap: 12,
        borderBottom: `1px solid ${theme.border}`, background: theme.chrome,
      }}>
        <svg width="14" height="14" viewBox="0 0 14 14">
          <circle cx="6" cy="6" r="4.2" stroke={theme.dim} strokeWidth="1.2" fill="none"/>
          <path d="M9.2 9.2 L12 12" stroke={theme.dim} strokeWidth="1.2" strokeLinecap="round"/>
        </svg>
        <span style={{ fontFamily: theme.font, fontSize: 13, color: theme.dim, flex: 1 }}>filter by name, path, or branch</span>
        <div style={{ display: 'flex', gap: 6 }}>
          {['all', 'pinned', 'this week'].map((f, i) => (
            <span key={i} style={{
              fontFamily: theme.font, fontSize: 11,
              color: i === 0 ? theme.text : theme.dim,
              background: i === 0 ? theme.accentSoft : 'transparent',
              padding: '4px 10px', borderRadius: 4,
              border: `1px solid ${i === 0 ? theme.borderActive : theme.border}`,
            }}>{f}</span>
          ))}
        </div>
      </div>

      {/* project list */}
      <div style={{ flex: 1, overflow: 'hidden' }}>
        {RECENT_PROJECTS.map((p, i) => <ProjectCard key={i} p={p} theme={theme} />)}
      </div>

      {/* footer */}
      <div style={{
        height: 32, display: 'flex', alignItems: 'center', gap: 14,
        padding: '0 24px', background: theme.chrome,
        fontFamily: theme.font, fontSize: 10, color: theme.dim,
      }}>
        <span>↑↓ navigate</span>
        <span>⏎ resume in current window</span>
        <span>⌘⏎ new window</span>
        <span style={{ marginLeft: 'auto' }}>4 projects · 1 pinned</span>
      </div>
    </div>
  );
}

// ─── Public wrapper ──────────────────────────────────────────
function BentoOverlay({ theme, overlay }) {
  return (
    <div style={{
      width: 1400, height: 900, position: 'relative',
      borderRadius: theme.windowRadius, overflow: 'hidden',
      background: theme.bg,
    }}>
      <DimmedBackdrop theme={theme} dim={theme === window.THEMES.paper ? 0.25 : 0.5} />
      {overlay === 'palette' && <CommandPalette theme={theme} />}
      {overlay === 'ripgrep' && <RipgrepPanel theme={theme} />}
      {overlay === 'resurrect' && <ResurrectLauncher theme={theme} />}
    </div>
  );
}

window.BentoOverlay = BentoOverlay;
