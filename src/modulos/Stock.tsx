import { useState, type FormEvent } from 'react'
import { BotonConfirmar, Encabezado, Insignia, Mensajes } from '../componentes/Comunes'
import { ajustarStock, cargarProductos, guardarProducto, type Producto } from '../servicios/negocio'
import { diasHasta, enteroValido, fechaCorta, montoValido } from '../servicios/formato'
import { useAccion, useCarga } from '../servicios/hooks'
import { useDinero } from '../servicios/privacidad'

const DIAS_AVISO_VENCIMIENTO = 7

type FormularioProducto = { id: string | null; nombre: string; precio: string; minimo: string; vencimiento: string; activo: boolean }
const formularioVacio: FormularioProducto = { id: null, nombre: '', precio: '', minimo: '0', vencimiento: '', activo: true }
type Ajuste = { id: string; stock: string; costo: string; motivo: string } | null

const bajoMinimo = (producto: Producto) => producto.activo && producto.stock <= producto.stock_minimo
const diasParaVencer = (producto: Producto) => producto.fecha_vencimiento ? diasHasta(producto.fecha_vencimiento) : null
const porVencer = (producto: Producto) => {
  const dias = diasParaVencer(producto)
  return producto.activo && dias !== null && dias <= DIAS_AVISO_VENCIMIENTO
}

function insigniasDe(producto: Producto) {
  const dias = diasParaVencer(producto)
  return <>
    {!producto.activo && <Insignia tono="neutro">Inactivo</Insignia>}
    {producto.activo && producto.stock === 0 && <Insignia tono="peligro">Sin stock</Insignia>}
    {producto.activo && producto.stock > 0 && bajoMinimo(producto) && <Insignia tono="alerta">Stock bajo</Insignia>}
    {producto.activo && dias !== null && dias < 0 && <Insignia tono="peligro">Vencido</Insignia>}
    {porVencer(producto) && dias !== null && dias >= 0 && <Insignia tono="alerta">{dias === 0 ? 'Vence hoy' : `Vence en ${dias} d`}</Insignia>}
  </>
}

export function Stock() {
  const { datos, error: errorCarga, cargando, recargar } = useCarga(cargarProductos)
  const { guardando, error, aviso, ejecutar, setError } = useAccion(recargar)
  const dinero = useDinero()
  const [formulario, setFormulario] = useState<FormularioProducto>(formularioVacio)
  const [ajuste, setAjuste] = useState<Ajuste>(null)

  const productos = datos ?? []
  const activos = productos.filter((producto) => producto.activo)
  const sinStock = activos.filter((producto) => producto.stock <= producto.stock_minimo).length
  const vencen = productos.filter(porVencer).length
  const bloqueado = !datos || guardando

  function enviarProducto(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault()
    const precio = montoValido(formulario.precio, true)
    const minimo = enteroValido(formulario.minimo, true)
    if (!formulario.nombre.trim()) return setError('Escribe el nombre del producto.')
    if (precio === null) return setError('El precio debe ser un número positivo o cero, con hasta dos decimales.')
    if (minimo === null) return setError('El stock mínimo debe ser un número entero, sin negativos.')
    void ejecutar(() => guardarProducto({
      id: formulario.id, nombre: formulario.nombre.trim(), precioVenta: precio, stockMinimo: minimo,
      vencimiento: formulario.vencimiento || null, activo: formulario.activo,
    }), formulario.id ? 'Producto actualizado.' : 'Producto creado. Ajusta su stock cuando tengas unidades.').then((ok) => {
      if (ok) setFormulario(formularioVacio)
    })
  }

  function editar(producto: Producto) {
    setError('')
    setFormulario({
      id: producto.id, nombre: producto.nombre, precio: String(producto.precio_venta), minimo: String(producto.stock_minimo),
      vencimiento: producto.fecha_vencimiento ?? '', activo: producto.activo,
    })
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }

  function enviarAjuste(evento: FormEvent<HTMLFormElement>, producto: Producto) {
    evento.preventDefault()
    if (!ajuste) return
    const nuevo = enteroValido(ajuste.stock, true)
    if (nuevo === null) return setError('El stock debe ser un número entero, sin negativos.')
    if (nuevo === producto.stock) return setError('El stock ya tiene ese valor.')
    if (ajuste.motivo.length > 300) return setError('El motivo es demasiado largo (máximo 300 caracteres).')
    let costo: number | null = null
    if (nuevo > producto.stock) {
      costo = montoValido(ajuste.costo, true)
      if (costo === null) return setError('Indica cuánto te costó cada unidad que agregas.')
    }
    void ejecutar(() => ajustarStock(producto.id, nuevo, costo, ajuste.motivo.trim()), 'Stock actualizado.').then((ok) => {
      if (ok) setAjuste(null)
    })
  }

  return <div className="finanzas-page modulo">
    <Encabezado cejilla="NEGOCIO · STOCK" titulo="Stock">
      Lo que tienes para vender. Al agregar unidades indica cuánto te costaron: así el costo promedio y la ganancia salen bien.
    </Encabezado>
    <Mensajes error={error || errorCarga} aviso={aviso} cargando={cargando} />

    <section className="finanzas-resumen" aria-label="Resumen de stock">
      <article><span>Productos activos</span><strong>{activos.length}</strong><small>Con precio de venta</small></article>
      <article><span>Stock bajo</span><strong className={sinStock > 0 ? 'balance-error' : undefined}>{sinStock}</strong><small>En o debajo del mínimo</small></article>
      <article><span>Por vencer</span><strong className={vencen > 0 ? 'balance-error' : undefined}>{vencen}</strong><small>En los próximos {DIAS_AVISO_VENCIMIENTO} días o ya vencidos</small></article>
    </section>

    <div className="finanzas-form-grid">
      <section className="finanzas-panel">
        <h2>{formulario.id ? 'Editar producto' : 'Nuevo producto'}</h2>
        <p>El stock no se edita aquí: se ajusta desde la lista de productos.</p>
        <form onSubmit={enviarProducto}><fieldset disabled={bloqueado}>
          <label htmlFor="producto-nombre">Nombre</label>
          <input id="producto-nombre" value={formulario.nombre} onChange={(e) => setFormulario({ ...formulario, nombre: e.target.value })} maxLength={80} placeholder="Producto" required />
          <div className="finanzas-dos">
            <div><label htmlFor="producto-precio">Precio de venta sugerido</label><input id="producto-precio" inputMode="decimal" value={formulario.precio} onChange={(e) => setFormulario({ ...formulario, precio: e.target.value })} placeholder="0.00" required /></div>
            <div><label htmlFor="producto-minimo">Stock mínimo</label><input id="producto-minimo" inputMode="numeric" value={formulario.minimo} onChange={(e) => setFormulario({ ...formulario, minimo: e.target.value })} required /></div>
          </div>
          <label htmlFor="producto-vence">Vencimiento (opcional)</label>
          <input id="producto-vence" type="date" value={formulario.vencimiento} onChange={(e) => setFormulario({ ...formulario, vencimiento: e.target.value })} />
          {formulario.id && <label className="casilla"><input type="checkbox" checked={formulario.activo} onChange={(e) => setFormulario({ ...formulario, activo: e.target.checked })} />Producto activo</label>}
          <div className="finanzas-dos">
            {formulario.id && <button type="button" className="finanzas-secundario" onClick={() => setFormulario(formularioVacio)}>Cancelar</button>}
            <button type="submit">{formulario.id ? 'Guardar cambios' : 'Crear producto'}</button>
          </div>
        </fieldset></form>
      </section>

      <section className="finanzas-panel"><h2>Tus productos</h2><p>Las alertas aparecen cuando el stock baja del mínimo o el producto vence pronto.</p>
        {productos.length === 0 && datos ? <p className="finanzas-vacio">Aún no tienes productos. Crea el primero.</p> : <ul className="lista">
          {productos.map((producto) => {
            const abierto = ajuste?.id === producto.id
            return <li key={producto.id} className={producto.activo ? 'tarjeta' : 'tarjeta tarjeta-apagada'}>
              <div className="tarjeta-fila">
                <div><strong>{producto.nombre}</strong> {insigniasDe(producto)}
                  <small>Precio {dinero(Number(producto.precio_venta))} · costo promedio {dinero(Number(producto.costo_promedio))}</small>
                  <small>Mínimo {producto.stock_minimo}{producto.fecha_vencimiento ? ` · vence ${fechaCorta(producto.fecha_vencimiento)}` : ''}</small>
                </div>
                <div className="tarjeta-monto"><b>{producto.stock}</b><small>unidades</small></div>
              </div>
              {!abierto && <div className="tarjeta-acciones">
                <button type="button" className="boton-suave" disabled={bloqueado} onClick={() => setAjuste({ id: producto.id, stock: String(producto.stock), costo: '', motivo: '' })}>Ajustar stock</button>
                <button type="button" className="boton-suave" disabled={bloqueado} onClick={() => editar(producto)}>Editar</button>
              </div>}
              {abierto && ajuste && <form className="tarjeta-form" onSubmit={(e) => enviarAjuste(e, producto)}><fieldset disabled={guardando}>
                <div className="finanzas-dos">
                  <div><label htmlFor={`stock-${producto.id}`}>Stock nuevo</label><input id={`stock-${producto.id}`} inputMode="numeric" value={ajuste.stock} onChange={(e) => setAjuste({ ...ajuste, stock: e.target.value })} required /></div>
                  <div><label htmlFor={`costo-${producto.id}`}>Costo por unidad agregada</label><input id={`costo-${producto.id}`} inputMode="decimal" value={ajuste.costo} onChange={(e) => setAjuste({ ...ajuste, costo: e.target.value })} placeholder="Solo si subes el stock" /></div>
                </div>
                <label htmlFor={`motivo-${producto.id}`}>Motivo (opcional)</label>
                <input id={`motivo-${producto.id}`} value={ajuste.motivo} onChange={(e) => setAjuste({ ...ajuste, motivo: e.target.value })} maxLength={300} placeholder="Inventario inicial, merma, consumo propio…" />
                <div className="finanzas-dos"><button type="button" className="finanzas-secundario" onClick={() => setAjuste(null)}>Cancelar</button><button type="submit">Guardar stock</button></div>
              </fieldset></form>}
              {producto.activo && <div className="tarjeta-acciones">
                <BotonConfirmar texto="Desactivar" deshabilitado={bloqueado} alConfirmar={() => void ejecutar(() => guardarProducto({
                  id: producto.id, nombre: producto.nombre, precioVenta: Number(producto.precio_venta), stockMinimo: producto.stock_minimo,
                  vencimiento: producto.fecha_vencimiento, activo: false,
                }), 'Producto desactivado.')} />
              </div>}
            </li>
          })}
        </ul>}
      </section>
    </div>
  </div>
}
