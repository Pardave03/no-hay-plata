import { supabase } from './supabase'
import { filas, rpc } from './rpc'
import { cuentasListas } from './deudas'
import type { Cuenta, Destino } from './finanzas'

export type Producto = {
  id: string
  nombre: string
  precio_venta: number
  costo_promedio: number
  stock: number
  stock_minimo: number
  fecha_vencimiento: string | null
  activo: boolean
}
export type ItemVenta = { producto_id: string; cantidad: number; precio_unitario: number; costo_unitario: number; subtotal: number }
export type Venta = {
  id: string; fecha: string; cliente: string | null; total: number; costo_total: number
  movimiento_id: string | null; deuda_id: string | null; nota: string | null; anulada_at: string | null
  venta_items: ItemVenta[]
}
export type ItemCompra = { producto_id: string; cantidad: number; subtotal: number; costo_unitario: number; fecha_vencimiento: string | null }
export type Compra = {
  id: string; fecha: string; proveedor: string | null; total: number; destino_dinero: Destino
  nota: string | null; anulada_at: string | null; compra_items: ItemCompra[]
}
export type DatosNegocio = { productos: Producto[]; ventas: Venta[]; compras: Compra[]; cuentas: Cuenta[] }

export async function cargarNegocio(): Promise<DatosNegocio> {
  const [productos, ventas, compras, cuentas] = await Promise.all([
    filas<Producto>(supabase.from('productos').select('id,nombre,precio_venta,costo_promedio,stock,stock_minimo,fecha_vencimiento,activo').order('nombre')),
    filas<Venta>(supabase.from('ventas').select('id,fecha,cliente,total,costo_total,movimiento_id,deuda_id,nota,anulada_at,venta_items(producto_id,cantidad,precio_unitario,costo_unitario,subtotal)').order('fecha', { ascending: false }).order('fecha_creacion', { ascending: false }).limit(100)),
    filas<Compra>(supabase.from('compras').select('id,fecha,proveedor,total,destino_dinero,nota,anulada_at,compra_items(producto_id,cantidad,subtotal,costo_unitario,fecha_vencimiento)').order('fecha', { ascending: false }).order('fecha_creacion', { ascending: false }).limit(100)),
    cuentasListas(),
  ])
  return { productos, ventas, compras, cuentas }
}

export const guardarProducto = (producto: { id: string | null; nombre: string; precioVenta: number; stockMinimo: number; vencimiento: string | null; activo: boolean }) =>
  rpc('productos_guardar', {
    p_id: producto.id, p_nombre: producto.nombre, p_precio_venta: producto.precioVenta,
    p_stock_minimo: producto.stockMinimo, p_fecha_vencimiento: producto.vencimiento, p_activo: producto.activo,
  })

export const ajustarStock = (productoId: string, nuevoStock: number, costoUnitario: number | null, motivo: string) =>
  rpc('productos_ajustar_stock', { p_producto_id: productoId, p_nuevo_stock: nuevoStock, p_costo_unitario: costoUnitario, p_motivo: motivo })

export type LineaCompra = { producto_id: string; cantidad: number; subtotal: number; fecha_vencimiento: string | null }
export const registrarCompra = (compra: { items: LineaCompra[]; cuentaId: string; destino: Destino; proveedor: string; nota: string; fecha: string }, operacionId: string) =>
  rpc('compras_registrar', {
    p_items: compra.items, p_cuenta_id: compra.cuentaId, p_destino: compra.destino, p_proveedor: compra.proveedor,
    p_nota: compra.nota, p_fecha: compra.fecha, p_operacion_id: operacionId,
  })

export const anularCompra = (compraId: string) =>
  rpc('compras_anular', { p_compra_id: compraId, p_operacion_id: crypto.randomUUID() })

export type LineaVenta = { producto_id: string; cantidad: number; precio_unitario: number }
/** Con `cuentaId` la venta se cobra ahora; sin ella queda fiada como deuda por cobrar. */
export const registrarVenta = (venta: { items: LineaVenta[]; cuentaId: string | null; cliente: string; vencimiento: string | null; nota: string; fecha: string }, operacionId: string) =>
  rpc('ventas_registrar', {
    p_items: venta.items, p_cuenta_id: venta.cuentaId, p_cliente: venta.cliente, p_fecha_vencimiento: venta.vencimiento,
    p_nota: venta.nota, p_fecha: venta.fecha, p_operacion_id: operacionId,
  })

export const anularVenta = (ventaId: string) =>
  rpc('ventas_anular', { p_venta_id: ventaId, p_operacion_id: crypto.randomUUID() })
