import { useState, type ReactNode } from 'react'

export function Encabezado({ cejilla, titulo, children }: { cejilla: string; titulo: string; children: ReactNode }) {
  return <>
    <div className="eyebrow">{cejilla}</div>
    <h1>{titulo}</h1>
    <p className="finanzas-intro">{children}</p>
  </>
}

export function Mensajes({ error, aviso, cargando }: { error?: string; aviso?: string; cargando?: boolean }) {
  return <>
    {error && <div className="app-error" role="alert">{error}</div>}
    {aviso && <div className="finanzas-exito" role="status">{aviso}</div>}
    {cargando && <p className="finanzas-cargando" role="status">Cargando…</p>}
  </>
}

export function Insignia({ tono, children }: { tono: 'ok' | 'alerta' | 'peligro' | 'neutro'; children: ReactNode }) {
  return <span className={`insignia insignia-${tono}`}>{children}</span>
}

export function Pestanas<T extends string>({ opciones, activa, elegir }: { opciones: { id: T; titulo: string }[]; activa: T; elegir: (id: T) => void }) {
  return <div className="pestanas" role="tablist">
    {opciones.map((opcion) => <button key={opcion.id} type="button" role="tab" aria-selected={activa === opcion.id} className={activa === opcion.id ? 'pestana pestana-activa' : 'pestana'} onClick={() => elegir(opcion.id)}>{opcion.titulo}</button>)}
  </div>
}

/** Botón de dos pasos para acciones que no se deshacen fácilmente (anular, eliminar). */
export function BotonConfirmar({ texto, alConfirmar, deshabilitado }: { texto: string; alConfirmar: () => void; deshabilitado?: boolean }) {
  const [pidiendo, setPidiendo] = useState(false)
  return <button type="button" className={pidiendo ? 'boton-peligro boton-peligro-activo' : 'boton-peligro'} disabled={deshabilitado}
    onBlur={() => setPidiendo(false)}
    onClick={() => { if (pidiendo) { setPidiendo(false); alConfirmar() } else setPidiendo(true) }}>
    {pidiendo ? '¿Confirmar?' : texto}
  </button>
}
