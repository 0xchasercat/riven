// RivenWorkspace — the full app mockup, parameterized by theme.
// Usage: <RivenWorkspace theme={THEMES.carbon} />

const { useState } = React;

// ─── Window chrome ───────────────────────────────────────────
function TrafficLights() {
  const dot = (c) => (
    <span style={{
      width: 12, height: 12, borderRadius: '50%', background: c,
      boxShadow: 'inset 0 0 0 0.5px rgba(0,0,0,0.18)',
    }} />
  );
  return (
    <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
      {dot('#ff5f57')}{dot('#febc2e')}{dot('#28c840')}
    </div>
  );
}

function TitleBar({ theme, project = '~/riven' }) {
  return (
    <div style={{
      height: 38, display: 'flex', alignItems: 'center', gap: 14,
      padding: '0 14px', background: theme.chrome,
      borderBottom: `1px solid ${theme.border}`, flexShrink: 0,
      position: 'relative',
    }}>
      <TrafficLights />
      {/* center-aligned project title */}
      <div style={{
        position: 'absolute', left: 0, right: 0, top: 0, bottom: 0,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        pointerEvents: 'none',
      }}>
        <div style={{
          fontFamily: theme.font, fontSize: 12, color: theme.dim,
          letterSpacing: 0.2,
        }}>
          <span style={{ color: theme.text, fontWeight: 500 }}>riven</span>
          <span style={{ margin: '0 8px' }}>—</span>
          {project}
          <span style={{ margin: '0 8px', color: theme.veryDim }}>·</span>
          <span style={{ color: theme.dim }}>main</span>
        </div>
      </div>
      {/* right side: layout indicator */}
      <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 10 }}>
        <LayoutGlyph theme={theme} />
        <Kbd theme={theme} keys={['⌘', 'K']} />
      </div>
    </div>
  );
}

function LayoutGlyph({ theme }) {
  // Tiny 2x2 glyph representing the current pane layout. Active cell filled.
  return (
    <svg width="18" height="14" viewBox="0 0 18 14" style={{ opacity: 0.85 }}>
      <rect x="0.5" y="0.5" width="10" height="6" fill={theme.accent} stroke="none" rx="1" />
      <rect x="11.5" y="0.5" width="6" height="6" fill="none" stroke={theme.dim} rx="1" />
      <rect x="0.5" y="7.5" width="10" height="6" fill="none" stroke={theme.dim} rx="1" />
      <rect x="11.5" y="7.5" width="6" height="6" fill="none" stroke={theme.dim} rx="1" />
    </svg>
  );
}

function Kbd({ theme, keys }) {
  return (
    <span style={{ display: 'inline-flex', gap: 2 }}>
      {keys.map((k, i) => (
        <span key={i} style={{
          fontFamily: theme.font, fontSize: 10, color: theme.dim,
          background: theme.accentSoft, padding: '2px 5px',
          borderRadius: 3, minWidth: 14, textAlign: 'center',
          border: `0.5px solid ${theme.border}`,
        }}>{k}</span>
      ))}
    </span>
  );
}

// ─── File tree ───────────────────────────────────────────────
function Caret({ open, color }) {
  return (
    <svg width="9" height="9" viewBox="0 0 9 9" style={{ flexShrink: 0, transform: open ? 'rotate(90deg)' : 'none', transition: 'transform .12s' }}>
      <path d="M3 2 L6 4.5 L3 7 Z" fill={color} />
    </svg>
  );
}

function FileIcon({ name, theme }) {
  // Tiny colored dot keyed off extension. Native-Mac aesthetic, no SVGs.
  const ext = name.split('.').pop();
  const map = {
    swift: '#f05238', rs: '#dea584', toml: '#9c7050',
    md: theme.dim, json: '#f0c04e', plist: theme.dim,
  };
  const c = map[ext] || theme.dim;
  return (
    <span style={{
      width: 7, height: 7, borderRadius: 1, background: c,
      flexShrink: 0, opacity: 0.85,
    }} />
  );
}

function TreeNode({ node, depth = 0, theme }) {
  const [open, setOpen] = useState(!!node.expanded);
  const pad = 8 + depth * 12;
  if (node.kind === 'group') {
    return (
      <>
        <div style={{
          padding: '10px 12px 4px',
          fontFamily: theme.font, fontSize: 10, fontWeight: 600,
          color: theme.dim, letterSpacing: 1.2,
        }}>{node.label}</div>
        {node.children.map((c, i) => <TreeNode key={i} node={c} depth={0} theme={theme} />)}
      </>
    );
  }
  if (node.kind === 'dir') {
    return (
      <>
        <div onClick={() => setOpen(!open)} style={{
          display: 'flex', alignItems: 'center', gap: 6,
          padding: `2px 8px 2px ${pad}px`, cursor: 'pointer',
          fontFamily: theme.font, fontSize: 12, color: theme.text,
        }}>
          <Caret open={open} color={theme.dim} />
          <span style={{ color: theme.text }}>{node.name}</span>
        </div>
        {open && node.children.map((c, i) => <TreeNode key={i} node={c} depth={depth + 1} theme={theme} />)}
      </>
    );
  }
  // file
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 8,
      padding: `2px 8px 2px ${pad + 14}px`, cursor: 'pointer',
      fontFamily: theme.font, fontSize: 12,
      color: node.active ? theme.text : (node.dirty ? theme.text : theme.dim),
      background: node.active ? theme.accentSoft : 'transparent',
      borderLeft: node.active ? `2px solid ${theme.borderActive}` : '2px solid transparent',
      marginLeft: -2,
      position: 'relative',
    }}>
      <FileIcon name={node.name} theme={theme} />
      <span style={{ flex: 1 }}>{node.name}</span>
      {node.dirty && (
        <span style={{
          width: 6, height: 6, borderRadius: '50%',
          background: node.active ? theme.borderActive : theme.dim,
          flexShrink: 0,
        }} />
      )}
    </div>
  );
}

function FileTree({ theme }) {
  return (
    <div style={{
      width: 220, flexShrink: 0, background: theme.chrome,
      borderRight: `1px solid ${theme.border}`,
      overflow: 'hidden', display: 'flex', flexDirection: 'column',
    }}>
      <div style={{
        height: 28, display: 'flex', alignItems: 'center',
        padding: '0 14px', borderBottom: `1px solid ${theme.border}`,
        fontFamily: theme.font, fontSize: 10, color: theme.dim,
        letterSpacing: 1.2, fontWeight: 600,
      }}>
        EXPLORER
        <span style={{ marginLeft: 'auto', color: theme.veryDim }}>2</span>
      </div>
      <div style={{ flex: 1, overflow: 'hidden', padding: '4px 0' }}>
        {window.RIVEN_CONTENT.FILE_TREE.map((n, i) => (
          <TreeNode key={i} node={n} theme={theme} />
        ))}
      </div>
    </div>
  );
}

// ─── Code rendering ──────────────────────────────────────────
function CodeLines({ lines, theme, startLine = 1, gutterWidth = 36, highlightLine = null }) {
  return (
    <div style={{
      fontFamily: theme.font, fontSize: 12, lineHeight: '18px',
      color: theme.text,
    }}>
      {lines.map((line, i) => {
        const ln = startLine + i;
        const isHl = ln === highlightLine;
        return (
          <div key={i} style={{
            display: 'flex',
            background: isHl ? theme.accentSoft : 'transparent',
          }}>
            <div style={{
              width: gutterWidth, flexShrink: 0, textAlign: 'right',
              padding: '0 10px 0 0', color: isHl ? theme.text : theme.veryDim,
              userSelect: 'none',
            }}>{ln}</div>
            <div style={{ whiteSpace: 'pre', flex: 1, paddingRight: 12 }}>
              {line.length === 0 ? '\u00A0' : line.map((seg, j) => (
                <span key={j} style={{ color: seg.t ? theme.sx[seg.t] : theme.text }}>
                  {seg.v}
                </span>
              ))}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ─── Terminal rendering ──────────────────────────────────────
function TermBody({ stream, theme, cursor = true }) {
  // stream is an array of {t,v} segments or '\n' strings
  return (
    <div style={{
      fontFamily: theme.font, fontSize: 12, lineHeight: '18px',
      color: theme.text, whiteSpace: 'pre-wrap', padding: '8px 14px',
    }}>
      {stream.map((seg, i) => {
        if (seg === '\n' || seg === '\n\n') return <span key={i}>{seg}</span>;
        if (seg.t === 'cursor') {
          return cursor ? <span key={i} style={{
            display: 'inline-block', width: 8, height: 14, verticalAlign: 'middle',
            background: theme.cursor, marginBottom: -2,
          }} /> : null;
        }
        const color = seg.t ? theme.term[seg.t] : theme.text;
        const weight = (seg.t === 'cmd' || seg.t === 'prompt') ? 600 : 400;
        return <span key={i} style={{ color, fontWeight: weight }}>{seg.v}</span>;
      })}
    </div>
  );
}

// ─── Pane ────────────────────────────────────────────────────
function PaneHeader({ title, badge, kind, active, theme, dirty }) {
  return (
    <div style={{
      height: 26, display: 'flex', alignItems: 'center',
      padding: '0 10px', gap: 8, flexShrink: 0,
      background: theme.paneHeaderBg,
      borderBottom: `1px solid ${theme.border}`,
      fontFamily: theme.font, fontSize: 11,
      color: active ? theme.text : theme.dim,
    }}>
      {/* kind glyph: editor vs terminal */}
      <KindGlyph kind={kind} color={active ? theme.borderActive : theme.dim} />
      <span style={{ fontWeight: active ? 600 : 400 }}>{title}</span>
      {dirty && (
        <span style={{
          width: 6, height: 6, borderRadius: '50%',
          background: active ? theme.borderActive : theme.dim,
        }} />
      )}
      {badge && (
        <span style={{
          marginLeft: 'auto', fontSize: 10, color: theme.dim,
          padding: '1px 6px', borderRadius: 3,
          border: `0.5px solid ${theme.border}`, background: theme.bg,
        }}>{badge}</span>
      )}
      {!badge && <span style={{ marginLeft: 'auto' }} />}
      {active && <span style={{
        width: 5, height: 5, borderRadius: '50%',
        background: theme.borderActive,
      }} />}
    </div>
  );
}

function KindGlyph({ kind, color }) {
  if (kind === 'term') {
    // terminal: angle bracket prompt
    return (
      <svg width="10" height="10" viewBox="0 0 10 10" style={{ flexShrink: 0 }}>
        <path d="M2 3 L4.5 5 L2 7" stroke={color} strokeWidth="1.2" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
        <path d="M5.5 7.5 L8.5 7.5" stroke={color} strokeWidth="1.2" strokeLinecap="round" />
      </svg>
    );
  }
  // editor: pencil/page mark
  return (
    <svg width="10" height="10" viewBox="0 0 10 10" style={{ flexShrink: 0 }}>
      <rect x="2" y="1.5" width="6" height="7" rx="0.8" stroke={color} strokeWidth="1" fill="none"/>
      <path d="M3.5 4 L6.5 4 M3.5 5.5 L6.5 5.5 M3.5 7 L5.5 7" stroke={color} strokeWidth="1" strokeLinecap="round"/>
    </svg>
  );
}

function Pane({ theme, kind, title, badge, active, dirty, children, scrollFade = true }) {
  return (
    <div style={{
      flex: 1, minHeight: 0, minWidth: 0,
      display: 'flex', flexDirection: 'column',
      background: active ? theme.panel : theme.panelInactive,
      borderRadius: theme.paneRadius,
      boxShadow: active ? theme.activeHighlight : 'none',
      position: 'relative', overflow: 'hidden',
    }}>
      <PaneHeader title={title} badge={badge} kind={kind} active={active} dirty={dirty} theme={theme} />
      <div style={{ flex: 1, overflow: 'hidden', position: 'relative' }}>
        <div style={{ position: 'absolute', inset: 0, overflow: 'hidden' }}>
          {children}
        </div>
        {scrollFade && (
          <div style={{
            position: 'absolute', left: 0, right: 0, bottom: 0, height: 28,
            background: `linear-gradient(to bottom, transparent, ${active ? theme.panel : theme.panelInactive})`,
            pointerEvents: 'none',
          }} />
        )}
      </div>
    </div>
  );
}

// ─── Pane grid (the 'multiplexer') ───────────────────────────
function PaneGrid({ theme }) {
  const dw = theme.dividerWeight;
  return (
    <div style={{
      flex: 1, minWidth: 0, background: theme.divider,
      display: 'grid', gridTemplateColumns: '1.4fr 1fr', gridTemplateRows: '1.3fr 1fr',
      gap: dw, padding: dw,
    }}>
      {/* top-left: Swift editor (active) */}
      <Pane theme={theme} kind="editor" title="PaneView.swift" badge="Swift" active dirty>
        <div style={{ height: '100%', overflow: 'hidden', padding: '8px 0 0 0' }}>
          <CodeLines lines={window.RIVEN_CONTENT.SWIFT_CODE} theme={theme} highlightLine={14} />
        </div>
      </Pane>

      {/* top-right: cargo run terminal */}
      <Pane theme={theme} kind="term" title="zsh — cargo run" badge="ghostty">
        <TermBody stream={window.RIVEN_CONTENT.TERM_CARGO} theme={theme} cursor={false} />
      </Pane>

      {/* bottom-left: Rust editor */}
      <Pane theme={theme} kind="editor" title="registry.rs" badge="Rust" dirty>
        <div style={{ height: '100%', overflow: 'hidden', padding: '8px 0 0 0' }}>
          <CodeLines lines={window.RIVEN_CONTENT.RUST_CODE} theme={theme} />
        </div>
      </Pane>

      {/* bottom-right: cargo test */}
      <Pane theme={theme} kind="term" title="zsh — cargo test" badge="ghostty">
        <TermBody stream={window.RIVEN_CONTENT.TERM_TEST} theme={theme} cursor={true} />
      </Pane>
    </div>
  );
}

// ─── Status bar ──────────────────────────────────────────────
function StatusBar({ theme }) {
  const Item = ({ children, accent }) => (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 5,
      fontFamily: theme.font, fontSize: 10.5,
      color: accent ? theme.borderActive : theme.statusText,
      letterSpacing: 0.2,
    }}>{children}</div>
  );
  const Sep = () => (
    <span style={{ width: 1, height: 10, background: theme.border, margin: '0 10px' }} />
  );
  return (
    <div style={{
      height: 24, flexShrink: 0, background: theme.statusBg,
      borderTop: `1px solid ${theme.border}`,
      display: 'flex', alignItems: 'center', padding: '0 12px',
    }}>
      <Item accent>
        <svg width="9" height="9" viewBox="0 0 9 9"><circle cx="2" cy="2" r="1.5" fill={theme.borderActive}/><path d="M2 3 L2 7 M2 7 L6 7 L6 5" stroke={theme.borderActive} strokeWidth="1" fill="none"/><circle cx="6" cy="5" r="1" fill="none" stroke={theme.borderActive} strokeWidth="1"/></svg>
        main
      </Item>
      <Sep />
      <Item>2 modified</Item>
      <Sep />
      <Item>4 panes · 2×2</Item>
      <Sep />
      <Item>ln 14, col 18</Item>
      <Sep />
      <Item>Swift · LF · UTF-8</Item>
      <div style={{ flex: 1 }} />
      <Item>⌘K palette</Item>
      <Sep />
      <Item>⌘P file</Item>
      <Sep />
      <Item>⌘⇧F search</Item>
      <Sep />
      <Item>43 MB · 0.4% CPU</Item>
    </div>
  );
}

// ─── Workspace (the full window) ─────────────────────────────
function RivenWorkspace({ theme, width = 1400, height = 900 }) {
  return (
    <div style={{
      width, height, background: theme.bg,
      borderRadius: theme.windowRadius, overflow: 'hidden',
      boxShadow: theme.shadow,
      display: 'flex', flexDirection: 'column',
      fontFamily: theme.uiFont,
      color: theme.text,
    }}>
      <TitleBar theme={theme} />
      <div style={{ flex: 1, display: 'flex', minHeight: 0 }}>
        <FileTree theme={theme} />
        <PaneGrid theme={theme} />
      </div>
      <StatusBar theme={theme} />
    </div>
  );
}

Object.assign(window, { RivenWorkspace, Kbd, TrafficLights });
