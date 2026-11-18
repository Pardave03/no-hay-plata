import { supabase } from './supabase'
import { comprobar, filas } from './rpc'
import type { Asignacion } from './finanzas'

// Tablas de apoyo sin dinero: la app escribe directamente y RLS limita cada fila a su dueño.

export type EstadoPedido = 'pendiente' | 'entregado' | 'cancelado'
export type Pedido = { id: string; cliente: string; detalle: string; monto_estimado: number | null; fecha_entrega: string | null; estado: EstadoPedido; fecha_creacion: string }

export const cargarPedidos = () => filas<Pedido>(
  supabase.from('pedidos').select('id,cliente,detalle,monto_estimado,fecha_entrega,estado,fecha_creacion').order('fecha_creacion', { ascending: false }).limit(300),
)
export async function crearPedido(pedido: { cliente: string; detalle: string; monto_estimado: number | null; fecha_entrega: string | null }) {
  comprobar((await supabase.from('pedidos').insert(pedido)).error)
}
export async function cambiarEstadoPedido(id: string, estado: EstadoPedido) {
  comprobar((await supabase.from('pedidos').update({ estado, fecha_actualizacion: new Date().toISOString() }).eq('id', id)).error)
}
export async function eliminarPedido(id: string) {
  comprobar((await supabase.from('pedidos').delete().eq('id', id)).error)
}

export type Meta = { id: string; nombre: string; monto_objetivo: number; monto_actual: number; fecha_objetivo: string | null }
export type DatosAhorros = { metas: Meta[]; ahorros: number; otros: Asignacion[] }

export async function cargarAhorros(): Promise<DatosAhorros> {
  const [metas, asignaciones] = await Promise.all([
    filas<Meta>(supabase.from('metas_ahorro').select('id,nombre,monto_objetivo,monto_actual,fecha_objetivo').order('fecha_creacion')),
    filas<Asignacion>(supabase.from('asignaciones_dinero').select('destino,monto')),
  ])
  return {
    metas,
    ahorros: Number(asignaciones.find((item) => item.destino === 'ahorros')?.monto ?? 0),
    otros: asignaciones.filter((item) => item.destino !== 'ahorros'),
  }
}
export async function crearMeta(meta: { nombre: string; monto_objetivo: number; fecha_objetivo: string | null }) {
  comprobar((await supabase.from('metas_ahorro').insert(meta)).error)
}
export async function actualizarMeta(id: string, cambios: Partial<Pick<Meta, 'nombre' | 'monto_objetivo' | 'monto_actual' | 'fecha_objetivo'>>) {
  comprobar((await supabase.from('metas_ahorro').update({ ...cambios, fecha_actualizacion: new Date().toISOString() }).eq('id', id)).error)
}
export async function eliminarMeta(id: string) {
  comprobar((await supabase.from('metas_ahorro').delete().eq('id', id)).error)
}

export type Hoja = { id: string; titulo: string; contenido: string; fecha_actualizacion: string }

export const cargarHojas = () => filas<Hoja>(
  supabase.from('hojas').select('id,titulo,contenido,fecha_actualizacion').order('fecha_actualizacion', { ascending: false }).limit(200),
)
export async function guardarHoja(hoja: { id: string | null; titulo: string; contenido: string }) {
  const datos = { titulo: hoja.titulo, contenido: hoja.contenido, fecha_actualizacion: new Date().toISOString() }
  const consulta = hoja.id ? supabase.from('hojas').update(datos).eq('id', hoja.id) : supabase.from('hojas').insert(datos)
  comprobar((await consulta).error)
}
export async function eliminarHoja(id: string) {
  comprobar((await supabase.from('hojas').delete().eq('id', id)).error)
}
