import { useState, type FormEvent } from 'react'
import { BotonConfirmar, Encabezado, Insignia, Mensajes, Pestanas } from '../componentes/Comunes'
import {
  anularDeuda, anularPagoDeuda, cargarDeudas, crearDeuda, registrarPagoDeuda, reprogramarDeuda,
  type Deuda, type TipoDeuda,
} from '../servicios/deudas'
import type { Destino } from '../servicios/finanzas'
import { diasHasta, etiqueta, fechaCorta, hoyLima, montoValido } from '../servicios/formato'
import { useAccion, useCarga, useOperacion } from '../servicios/hooks'
import { useDinero } from '../servicios/privacidad'

const destinos: Destino[] = ['personal', 'negocio', 'ahorros']
const formularioVacio = { tipo: 'por_cobrar' as TipoDeuda, persona: '', concepto: '', monto: '', destino: 'personal' as Destino, categoriaId: '', vencimiento: '', mueveDinero: false, cuentaId: '' }

type Vista = 'activas' | 'cerradas'
type Abierto = { id: string; modo: 'pago' | 'fecha'; monto: string; cuentaId: string; fecha: string } | null

function estadoVisible(deuda: Deuda) {
  if (deuda.estado === 'pagada') return <Insignia tono="ok">Pagada</Insignia>
  if (deuda.estado === 'anulada') return <Insignia tono="neutro">Anulada</Insignia>
  const dias = deuda.fecha_vencimiento ? diasHasta(deuda.fecha_vencimiento) : null
  if (dias !== null && dias < 0) return <Insignia tono="peligro">Vencida</Insignia>
  if (dias !== null && dias <= 7) return <Insignia tono="alerta">{dias === 0 ? 'Vence hoy' : `Vence en ${dias} d`}</Insignia>
  return <Insignia tono="neutro">{deuda.estado === 'parcial' ? 'Pago parcial' : 'Pendiente'}</Insignia>
}

export function Deudas() {
  const { datos, error: errorCarga, cargando, recargar } = useCarga(cargarDeudas)
  const { guardando, error, aviso, ejecutar, setError } = useAccion(recargar)
  const dinero = useDinero()
  const [formulario, setFormulario] = useState(formularioVacio)
  const [operacion, renovarOperacion] = useOperacion()
  const [operacionPago, renovarOperacionPago] = useOperacion()
  const [vista, setVista] = useState<Vista>('activas')
  const [abierto, setAbierto] = useState<Abierto>(null)

  const deudas = datos?.deudas ?? []
  const cuentas = datos?.cuentas ?? []
  const activas = deudas.filter((deuda) => deuda.estado === 'pendiente' || deuda.estado === 'parcial')
  const visibles = vista === 'activas' ? activas : deudas.filter((deuda) => deuda.estado === 'pagada' || deuda.estado === 'anulada')
  const totalDe = (tipo: TipoDeuda) => activas.filter((deuda) => deuda.tipo === tipo).reduce((suma, deuda) => suma + Number(deuda.saldo), 0)
  const vencidas = activas.filter((deuda) => deuda.fecha_vencimiento && diasHasta(deuda.fecha_vencimiento) < 0).length
  const tipoCategoria = formulario.tipo === 'por_cobrar' ? 'ingreso' : 'gasto'
  const bloqueado = !datos || guardando

  function enviar(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault()
    const monto = montoValido(formulario.monto)
    if (!formulario.persona.trim() || monto === null) return setError('Escribe la persona y un monto positivo con hasta dos decimales.')
    if (formulario.mueveDinero && !formulario.cuentaId) return setError('Elige la cuenta por la que se movió el dinero del préstamo.')
    void ejecutar(() => crearDeuda({
      tipo: formulario.tipo, persona: formulario.persona.trim(), concepto: formulario.concepto, monto,
      destino: formulario.destino, categoriaId: formulario.categoriaId || null,
      vencimiento: formulario.vencimiento || null, cuentaId: formulario.mueveDinero ? formulario.cuentaId : null,
    }, operacion), 'Deuda registrada.').then((ok) => {
      if (!ok) return
      setFormulario((actual) => ({ ...formularioVacio, tipo: actual.tipo }))
      renovarOperacion()
    })
  }

  function enviarAbierto(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault()
    if (!abierto) return
    if (abierto.modo === 'fecha') {
      void ejecutar(() => reprogramarDeuda(abierto.id, abierto.fecha || null), 'Vencimiento actualizado.').then((ok) => { if (ok) setAbierto(null) })
      return
    }
    const monto = montoValido(abierto.monto)
    if (monto === null || !abierto.cuentaId) return setError('Elige una cuenta e introduce un monto positivo.')
    if (!abierto.fecha || abierto.fecha > hoyLima()) return setError('Elige una fecha que no esté en el futuro.')
    void ejecutar(() => registrarPagoDeuda(abierto.id, monto, abierto.cuentaId, abierto.fecha, operacionPago), 'Pago registrado.').then((ok) => {
      if (!ok) return
      setAbierto(null)
      renovarOperacionPago()
    })
  }

  return <div className="finanzas-page modulo">
    <Encabezado cejilla="LO QUE DEBES Y TE DEBEN" titulo="Deudas">
      Registra lo que te deben (como pagos pendientes de tu trabajo) y lo que debes. Cada pago parcial reduce el saldo y queda en el historial.
    </Encabezado>
    <Mensajes error={error || errorCarga} aviso={aviso} cargando={cargando} />

    <section className="finanzas-resumen" aria-label="Resumen de deudas">
      <article><span>Me deben</span><strong className="balance-ok">{dinero(totalDe('por_cobrar'))}</strong><small>Saldo pendiente por cobrar</small></article>
      <article><span>Debo</span><strong className={totalDe('por_pagar') > 0 ? 'balance-error' : undefined}>{dinero(totalDe('por_pagar'))}</strong><small>Saldo pendiente por pagar</small></article>
      <article><span>Vencidas</span><strong className={vencidas > 0 ? 'balance-error' : undefined}>{vencidas}</strong><small>Deudas activas con fecha pasada</small></article>
    </section>

    <div className="finanzas-form-grid">
      <section className="finanzas-panel"><h2>Nueva deuda</h2><p>Si es un pago pendiente (por ejemplo, de tu trabajo), no marques la casilla del préstamo: el dinero entrará cuando registres el cobro.</p>
        <form onSubmit={enviar}><fieldset disabled={bloqueado}>
          <div className="finanzas-dos">
            <div><label htmlFor="deuda-tipo">Tipo</label><select id="deuda-tipo" value={formulario.tipo} onChange={(e) => setFormulario({ ...formulario, tipo: e.target.value as TipoDeuda, categoriaId: '' })}><option value="por_cobrar">Me deben</option><option value="por_pagar">Debo</option></select></div>
            <div><label htmlFor="deuda-monto">Monto</label><input id="deuda-monto" inputMode="decimal" value={formulario.monto} onChange={(e) => setFormulario({ ...formulario, monto: e.target.value })} placeholder="0.00" required /></div>
          </div>
          <label htmlFor="deuda-persona">{formulario.tipo === 'por_cobrar' ? '¿Quién te debe?' : '¿A quién le debes?'}</label>
          <input id="deuda-persona" value={formulario.persona} onChange={(e) => setFormulario({ ...formulario, persona: e.target.value })} maxLength={80} placeholder="Nombre" required />
          <label htmlFor="deuda-concepto">Concepto (opcional)</label>
          <input id="deuda-concepto" value={formulario.concepto} onChange={(e) => setFormulario({ ...formulario, concepto: e.target.value })} maxLength={300} placeholder="Turnos del fin de semana" />
          <div className="finanzas-dos">
            <div><label htmlFor="deuda-destino">Destino del dinero</label><select id="deuda-destino" value={formulario.destino} onChange={(e) => setFormulario({ ...formulario, destino: e.target.value as Destino })}>{destinos.map((destino) => <option value={destino} key={destino}>{etiqueta(destino)}</option>)}</select></div>
            <div><label htmlFor="deuda-categoria">Categoría (opcional)</label><select id="deuda-categoria" value={formulario.categoriaId} onChange={(e) => setFormulario({ ...formulario, categoriaId: e.target.value })}><option value="">Sin categoría</option>{datos?.categorias.filter((item) => item.tipo === tipoCategoria).map((item) => <option value={item.id} key={item.id}>{item.nombre}</option>)}</select></div>
          </div>
          <label htmlFor="deuda-vence">Vencimiento (opcional)</label>
          <input id="deuda-vence" type="date" value={formulario.vencimiento} onChange={(e) => setFormulario({ ...formulario, vencimiento: e.target.value })} />
          <label className="casilla"><input type="checkbox" checked={formulario.mueveDinero} onChange={(e) => setFormulario({ ...formulario, mueveDinero: e.target.checked })} />{formulario.tipo === 'por_cobrar' ? 'Es un préstamo: el dinero ya salió de una cuenta mía' : 'Es un préstamo: el dinero ya entró a una cuenta mía'}</label>
          {formulario.mueveDinero && <><label htmlFor="deuda-cuenta">Cuenta</label><select id="deuda-cuenta" value={formulario.cuentaId} onChange={(e) => setFormulario({ ...formulario, cuentaId: e.target.value })} required><option value="">Selecciona una cuenta</option>{cuentas.map((cuenta) => <option value={cuenta.id} key={cuenta.id}>{cuenta.nombre}</option>)}</select></>}
          <button type="submit">Registrar deuda</button>
        </fieldset></form>
      </section>

      <section className="finanzas-panel"><h2>Tus deudas</h2><p>Cobrar una deuda crea un ingreso en Finanzas; pagar una, un gasto. No tienes que registrarlo dos veces.</p>
        <Pestanas opciones={[{ id: 'activas', titulo: `Activas (${activas.length})` }, { id: 'cerradas', titulo: 'Pagadas y anuladas' }]} activa={vista} elegir={setVista} />
        {visibles.length === 0 ? <p className="finanzas-vacio">{vista === 'activas' ? 'No tienes deudas activas. ¡Bien ahí!' : 'Aún no hay deudas cerradas.'}</p> : <ul className="lista">
          {visibles.map((deuda) => {
            const pagos = datos?.pagos.filter((pago) => pago.deuda_id === deuda.id) ?? []
            const activa = deuda.estado === 'pendiente' || deuda.estado === 'parcial'
            const cobrar = deuda.tipo === 'por_cobrar'
            return <li key={deuda.id} className={deuda.estado === 'anulada' ? 'tarjeta tarjeta-apagada' : 'tarjeta'}>
              <div className="tarjeta-fila">
                <div><strong>{deuda.persona}</strong> {estadoVisible(deuda)}
                  <small>{cobrar ? 'Me debe' : 'Le debo'}{deuda.concepto ? ` · ${deuda.concepto}` : ''}{deuda.origen === 'venta' ? ' · venta fiada' : ''}{deuda.movimiento_inicial_id ? ' · préstamo' : ''}</small>
                  <small>Desde {fechaCorta(deuda.fecha_origen)}{deuda.fecha_vencimiento ? ` · vence ${fechaCorta(deuda.fecha_vencimiento)}` : ' · sin vencimiento'}</small>
                </div>
                <div className="tarjeta-monto"><b>{dinero(Number(deuda.saldo))}</b><small>de {dinero(Number(deuda.monto_total))}</small></div>
              </div>
              {activa && abierto?.id !== deuda.id && <div className="tarjeta-acciones">
                <button type="button" className="boton-suave" disabled={bloqueado || cuentas.length === 0} onClick={() => setAbierto({ id: deuda.id, modo: 'pago', monto: String(deuda.saldo), cuentaId: cuentas[0]?.id ?? '', fecha: hoyLima() })}>{cobrar ? 'Registrar cobro' : 'Registrar pago'}</button>
                <button type="button" className="boton-suave" disabled={bloqueado} onClick={() => setAbierto({ id: deuda.id, modo: 'fecha', monto: '', cuentaId: '', fecha: deuda.fecha_vencimiento ?? '' })}>Cambiar vencimiento</button>
                {deuda.origen === 'manual' && pagos.every((pago) => pago.anulado_at) && <BotonConfirmar texto="Anular deuda" deshabilitado={bloqueado} alConfirmar={() => void ejecutar(() => anularDeuda(deuda.id), 'Deuda anulada.')} />}
              </div>}
              {abierto?.id === deuda.id && <form className="tarjeta-form" onSubmit={enviarAbierto}><fieldset disabled={guardando}>
                {abierto.modo === 'pago' ? <>
                  <div className="finanzas-dos">
                    <div><label htmlFor="pago-monto">Monto</label><input id="pago-monto" inputMode="decimal" value={abierto.monto} onChange={(e) => setAbierto({ ...abierto, monto: e.target.value })} required /></div>
                    <div><label htmlFor="pago-fecha">Fecha</label><input id="pago-fecha" type="date" max={hoyLima()} value={abierto.fecha} onChange={(e) => setAbierto({ ...abierto, fecha: e.target.value })} required /></div>
                  </div>
                  <label htmlFor="pago-cuenta">{cobrar ? '¿A qué cuenta entró?' : '¿De qué cuenta salió?'}</label>
                  <select id="pago-cuenta" value={abierto.cuentaId} onChange={(e) => setAbierto({ ...abierto, cuentaId: e.target.value })} required>{cuentas.map((cuenta) => <option value={cuenta.id} key={cuenta.id}>{cuenta.nombre}</option>)}</select>
                </> : <><label htmlFor="nueva-fecha">Nuevo vencimiento (vacío para quitarlo)</label><input id="nueva-fecha" type="date" value={abierto.fecha} onChange={(e) => setAbierto({ ...abierto, fecha: e.target.value })} /></>}
                <div className="finanzas-dos"><button type="button" className="finanzas-secundario" onClick={() => setAbierto(null)}>Cancelar</button><button type="submit">Guardar</button></div>
              </fieldset></form>}
              {pagos.length > 0 && <ul className="tarjeta-detalle">
                {pagos.map((pago) => <li key={pago.id} className={pago.anulado_at ? 'finanzas-anulado' : undefined}>
                  <span>{fechaCorta(pago.fecha)} · {cobrar ? 'cobro' : 'pago'}{pago.anulado_at ? ' anulado' : ''}</span>
                  <span><b>{dinero(Number(pago.monto))}</b>{!pago.anulado_at && deuda.estado !== 'anulada' && <> <BotonConfirmar texto="Anular" deshabilitado={bloqueado} alConfirmar={() => void ejecutar(() => anularPagoDeuda(pago.id), 'Pago anulado.')} /></>}</span>
                </li>)}
              </ul>}
            </li>
          })}
        </ul>}
      </section>
    </div>
  </div>
}
