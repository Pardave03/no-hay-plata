import { useEffect, useState, type FormEvent } from 'react'
import {
  cargarFinanzas, crearCuenta, registrarSaldoInicial, registrarMovimiento,
  transferir, redistribuir, ModuloNoDisponible,
  type DatosFinanzas, type Destino, type TipoCuenta,
} from '../servicios/finanzas'
import '../estilos/finanzas.css'

const destinos: Destino[] = ['personal', 'negocio', 'ahorros']
const dinero = (valor: number) => new Intl.NumberFormat('es-PE', { style: 'currency', currency: 'PEN' }).format(valor)
const etiqueta = (valor: string) => valor.replaceAll('_', ' ').replace(/^./, (letra) => letra.toUpperCase())

function montoValido(valor: string, permiteCero = false): number | null {
  const limpio = valor.trim().replace(',', '.')
  if (!/^\d+(?:\.\d{1,2})?$/.test(limpio)) return null
  const numero = Number(limpio)
  return Number.isFinite(numero) && (permiteCero ? numero >= 0 : numero > 0) ? numero : null
}

function centimos(valor: number) { return Math.round(valor * 100) }

export function Finanzas({ usuarioId }: { usuarioId: string }) {
  const [datos, setDatos] = useState<DatosFinanzas | null>(null)
  const [revision, setRevision] = useState(0)
  const [cargando, setCargando] = useState(true)
  const [disponible, setDisponible] = useState(true)
  const [error, setError] = useState('')
  const [aviso, setAviso] = useState('')
  const [guardando, setGuardando] = useState('')
  const [cuenta, setCuenta] = useState<{ nombre: string; tipo: TipoCuenta }>({ nombre: '', tipo: 'banco' })
  const [inicial, setInicial] = useState({ cuentaId: '', monto: '', personal: '', negocio: '', ahorros: '' })
  const [movimiento, setMovimiento] = useState<{ cuentaId: string; tipo: 'ingreso' | 'gasto'; monto: string; destino: Destino; descripcion: string; categoriaId: string }>({ cuentaId: '', tipo: 'gasto', monto: '', destino: 'personal', descripcion: '', categoriaId: '' })
  const [transferencia, setTransferencia] = useState({ origenId: '', destinoId: '', monto: '', descripcion: '' })
  const [redistribucion, setRedistribucion] = useState<{ origen: Destino; destino: Destino; monto: string; descripcion: string }>({ origen: 'personal', destino: 'ahorros', monto: '', descripcion: '' })
  const [operaciones, setOperaciones] = useState(() => ({ inicial: crypto.randomUUID(), movimiento: crypto.randomUUID(), transferencia: crypto.randomUUID(), redistribucion: crypto.randomUUID() }))

  useEffect(() => {
    let activo = true
    cargarFinanzas(usuarioId).then((resultado) => {
      if (!activo) return
      setDatos(resultado)
      setDisponible(true)
      setError('')
    }).catch((fallo: unknown) => {
      if (!activo) return
      if (fallo instanceof ModuloNoDisponible) setDisponible(false)
      setError(fallo instanceof Error ? fallo.message : 'No se pudieron cargar las finanzas.')
    }).finally(() => { if (activo) setCargando(false) })
    return () => { activo = false }
  }, [usuarioId, revision])

  const cuentas = datos?.cuentas ?? []
  const activas = cuentas.filter((item) => item.activa)
  const inicializadas = activas.filter((item) => item.saldo_inicial_definido_at !== null)
  const pendientes = activas.filter((item) => item.saldo_inicial_definido_at === null)
  const asignaciones = datos?.asignaciones ?? []
  const totalFisico = cuentas.reduce((total, item) => total + Number(item.saldo), 0)
  const totalDestinos = asignaciones.reduce((total, item) => total + Number(item.monto), 0)
  const listo = disponible && datos !== null && !cargando

  async function ejecutar(nombre: string, accion: () => Promise<void>, despues: () => void) {
    setGuardando(nombre)
    setError('')
    setAviso('')
    try {
      await accion()
      despues()
      setAviso('Operación registrada correctamente.')
      setCargando(true)
      setRevision((actual) => actual + 1)
    } catch (fallo) {
      setError(fallo instanceof Error ? fallo.message : 'No se pudo completar la operación.')
    } finally {
      setGuardando('')
    }
  }

  function renovarOperacion(tipo: keyof typeof operaciones) {
    setOperaciones((actual) => ({ ...actual, [tipo]: crypto.randomUUID() }))
  }

  function enviarCuenta(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault()
    if (!cuenta.nombre.trim()) return setError('Escribe un nombre para la cuenta.')
    void ejecutar('cuenta', () => crearCuenta(cuenta.nombre.trim(), cuenta.tipo), () => setCuenta({ nombre: '', tipo: 'banco' }))
  }

  function enviarInicial(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault()
    const valores = [inicial.monto, inicial.personal, inicial.negocio, inicial.ahorros].map((valor) => montoValido(valor, true))
    if (!inicial.cuentaId || valores.some((valor) => valor === null)) return setError('Elige una cuenta e introduce montos no negativos con hasta dos decimales.')
    const [monto, personal, negocio, ahorros] = valores as number[]
    if (centimos(personal) + centimos(negocio) + centimos(ahorros) !== centimos(monto)) return setError('La suma de personal, negocio y ahorros debe coincidir con el saldo inicial.')
    void ejecutar('inicial', () => registrarSaldoInicial(inicial.cuentaId, monto, personal, negocio, ahorros, operaciones.inicial), () => {
      setInicial({ cuentaId: '', monto: '', personal: '', negocio: '', ahorros: '' })
      renovarOperacion('inicial')
    })
  }

  function enviarMovimiento(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault()
    const monto = montoValido(movimiento.monto)
    if (!movimiento.cuentaId || monto === null) return setError('Elige una cuenta e introduce un monto positivo con hasta dos decimales.')
    void ejecutar('movimiento', () => registrarMovimiento(movimiento.cuentaId, movimiento.tipo, monto, movimiento.destino, movimiento.descripcion, movimiento.categoriaId || null, operaciones.movimiento), () => {
      setMovimiento((actual) => ({ ...actual, monto: '', descripcion: '', categoriaId: '' }))
      renovarOperacion('movimiento')
    })
  }

  function enviarTransferencia(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault()
    const monto = montoValido(transferencia.monto)
    if (!transferencia.origenId || !transferencia.destinoId || transferencia.origenId === transferencia.destinoId || monto === null) return setError('Elige dos cuentas distintas y un monto positivo.')
    void ejecutar('transferencia', () => transferir(transferencia.origenId, transferencia.destinoId, monto, transferencia.descripcion, operaciones.transferencia), () => {
      setTransferencia({ origenId: '', destinoId: '', monto: '', descripcion: '' })
      renovarOperacion('transferencia')
    })
  }

  function enviarRedistribucion(evento: FormEvent<HTMLFormElement>) {
    evento.preventDefault()
    const monto = montoValido(redistribucion.monto)
    if (redistribucion.origen === redistribucion.destino || monto === null) return setError('Elige dos destinos distintos y un monto positivo.')
    void ejecutar('redistribucion', () => redistribuir(redistribucion.origen, redistribucion.destino, monto, redistribucion.descripcion, operaciones.redistribucion), () => {
      setRedistribucion((actual) => ({ ...actual, monto: '', descripcion: '' }))
      renovarOperacion('redistribucion')
    })
  }

  return <div className="finanzas-page">
    <div className="eyebrow">TU DINERO EN ORDEN</div>
    <h1>Finanzas</h1>
    <p className="finanzas-intro">Tus cuentas muestran dónde está el dinero. Los destinos muestran para qué lo reservaste.</p>
    {error && <div className="app-error" role="alert">{error}</div>}
    {aviso && <div className="finanzas-exito" role="status">{aviso}</div>}
    {!disponible && <div className="finanzas-pendiente">La interfaz está preparada. Las operaciones se habilitarán cuando se apruebe y aplique la migración SQL de Finanzas.</div>}
    {cargando && <p className="finanzas-cargando" role="status">Cargando datos financieros…</p>}
    <section className="finanzas-resumen" aria-label="Resumen de saldos">
      <article><span>Saldo en cuentas físicas</span><strong>{datos ? dinero(totalFisico) : '—'}</strong><small>Banco / Yape, efectivo y otras cuentas</small></article>
      <article><span>Dinero distribuido</span><strong>{datos ? dinero(totalDestinos) : '—'}</strong><small>Personal + negocio + ahorros</small></article>
      <article><span>Conciliación</span><strong className={datos && Math.abs(totalFisico - totalDestinos) < 0.001 ? 'balance-ok' : 'balance-error'}>{datos ? Math.abs(totalFisico - totalDestinos) < 0.001 ? 'Cuadra' : 'Revisar' : '—'}</strong><small>Ambos totales deben coincidir</small></article>
    </section>
    <section className="finanzas-panel"><div className="finanzas-heading"><div><h2>Cuentas físicas</h2><p>Banco y Yape pueden registrarse como una sola cuenta si comparten el mismo saldo.</p></div></div>
      {cuentas.length === 0 ? <p className="finanzas-vacio">Todavía no hay cuentas registradas.</p> : <div className="finanzas-cuentas">{cuentas.map((item) => <div className="finanzas-cuenta" key={item.id}><span className="finanzas-cuenta-icon">◈</span><div><strong>{item.nombre}</strong><small>{etiqueta(item.tipo)} · {item.saldo_inicial_definido_at ? 'Saldo inicial registrado' : 'Saldo inicial pendiente'}</small></div><b>{dinero(Number(item.saldo))}</b></div>)}</div>}
    </section>
    <section className="finanzas-destinos" aria-label="Distribución por destino">{destinos.map((destino) => <article key={destino} className={`finanzas-destino destino-${destino}`}><span>{etiqueta(destino)}</span><strong>{dinero(Number(asignaciones.find((item) => item.destino === destino)?.monto ?? 0))}</strong></article>)}</section>
    <div className="finanzas-form-grid">
      <section className="finanzas-panel"><h2>Nueva cuenta</h2><p>Una cuenta representa un lugar físico donde guardas dinero.</p><form onSubmit={enviarCuenta}><fieldset disabled={!listo || guardando !== ''}><label htmlFor="cuenta-nombre">Nombre</label><input id="cuenta-nombre" value={cuenta.nombre} onChange={(e) => setCuenta({ ...cuenta, nombre: e.target.value })} placeholder="Banco / Yape" maxLength={80} required /><label htmlFor="cuenta-tipo">Tipo</label><select id="cuenta-tipo" value={cuenta.tipo} onChange={(e) => setCuenta({ ...cuenta, tipo: e.target.value as TipoCuenta })}><option value="banco">Banco</option><option value="billetera_digital">Billetera digital</option><option value="efectivo">Efectivo</option><option value="otro">Otro</option></select><button type="submit">Crear cuenta</button></fieldset></form></section>
      <section className="finanzas-panel"><h2>Saldo inicial</h2><p>Se registra una sola vez por cuenta. Puedes registrar cero.</p><form onSubmit={enviarInicial}><fieldset disabled={!listo || guardando !== '' || pendientes.length === 0}><label htmlFor="inicial-cuenta">Cuenta</label><select id="inicial-cuenta" value={inicial.cuentaId} onChange={(e) => setInicial({ ...inicial, cuentaId: e.target.value })} required><option value="">Selecciona una cuenta</option>{pendientes.map((item) => <option value={item.id} key={item.id}>{item.nombre}</option>)}</select><label htmlFor="inicial-monto">Total inicial</label><input id="inicial-monto" inputMode="decimal" value={inicial.monto} onChange={(e) => setInicial({ ...inicial, monto: e.target.value })} placeholder="0.00" required /><div className="finanzas-triple">{destinos.map((destino) => <div key={destino}><label htmlFor={`inicial-${destino}`}>{etiqueta(destino)}</label><input id={`inicial-${destino}`} inputMode="decimal" value={inicial[destino]} onChange={(e) => setInicial({ ...inicial, [destino]: e.target.value })} placeholder="0.00" required /></div>)}</div><button type="submit">Registrar saldo inicial</button></fieldset></form></section>
      <section className="finanzas-panel"><h2>Ingreso o gasto</h2><p>Elige la cuenta física y el destino del dinero.</p><form onSubmit={enviarMovimiento}><fieldset disabled={!listo || guardando !== '' || inicializadas.length === 0}><label htmlFor="mov-tipo">Operación</label><select id="mov-tipo" value={movimiento.tipo} onChange={(e) => setMovimiento({ ...movimiento, tipo: e.target.value as 'ingreso' | 'gasto', categoriaId: '' })}><option value="gasto">Gasto</option><option value="ingreso">Ingreso</option></select><label htmlFor="mov-cuenta">Cuenta</label><select id="mov-cuenta" value={movimiento.cuentaId} onChange={(e) => setMovimiento({ ...movimiento, cuentaId: e.target.value })} required><option value="">Selecciona una cuenta</option>{inicializadas.map((item) => <option value={item.id} key={item.id}>{item.nombre}</option>)}</select><div className="finanzas-dos"><div><label htmlFor="mov-monto">Monto</label><input id="mov-monto" inputMode="decimal" value={movimiento.monto} onChange={(e) => setMovimiento({ ...movimiento, monto: e.target.value })} placeholder="0.00" required /></div><div><label htmlFor="mov-destino">Destino</label><select id="mov-destino" value={movimiento.destino} onChange={(e) => setMovimiento({ ...movimiento, destino: e.target.value as Destino })}>{destinos.map((destino) => <option value={destino} key={destino}>{etiqueta(destino)}</option>)}</select></div></div><label htmlFor="mov-categoria">Categoría (opcional)</label><select id="mov-categoria" value={movimiento.categoriaId} onChange={(e) => setMovimiento({ ...movimiento, categoriaId: e.target.value })}><option value="">Sin categoría</option>{datos?.categorias.filter((item) => item.tipo === movimiento.tipo).map((item) => <option value={item.id} key={item.id}>{item.nombre}</option>)}</select><label htmlFor="mov-descripcion">Descripción (opcional)</label><input id="mov-descripcion" value={movimiento.descripcion} onChange={(e) => setMovimiento({ ...movimiento, descripcion: e.target.value })} maxLength={300} placeholder="¿En qué se fue?" /><button type="submit">Registrar {movimiento.tipo}</button></fieldset></form></section>
      <section className="finanzas-panel"><h2>Transferir entre cuentas</h2><p>Mueve dinero físico sin crear un ingreso o gasto.</p><form onSubmit={enviarTransferencia}><fieldset disabled={!listo || guardando !== '' || inicializadas.length < 2}><label htmlFor="trans-origen">Desde</label><select id="trans-origen" value={transferencia.origenId} onChange={(e) => setTransferencia({ ...transferencia, origenId: e.target.value })} required><option value="">Cuenta de origen</option>{inicializadas.map((item) => <option value={item.id} key={item.id}>{item.nombre}</option>)}</select><label htmlFor="trans-destino">Hacia</label><select id="trans-destino" value={transferencia.destinoId} onChange={(e) => setTransferencia({ ...transferencia, destinoId: e.target.value })} required><option value="">Cuenta de destino</option>{inicializadas.map((item) => <option value={item.id} key={item.id}>{item.nombre}</option>)}</select><label htmlFor="trans-monto">Monto</label><input id="trans-monto" inputMode="decimal" value={transferencia.monto} onChange={(e) => setTransferencia({ ...transferencia, monto: e.target.value })} placeholder="0.00" required /><label htmlFor="trans-descripcion">Descripción (opcional)</label><input id="trans-descripcion" value={transferencia.descripcion} onChange={(e) => setTransferencia({ ...transferencia, descripcion: e.target.value })} maxLength={300} /><button type="submit">Transferir dinero</button></fieldset></form></section>
      <section className="finanzas-panel"><h2>Redistribuir destinos</h2><p>Cambia la finalidad del dinero sin moverlo de cuenta.</p><form onSubmit={enviarRedistribucion}><fieldset disabled={!listo || guardando !== '' || totalDestinos <= 0}><div className="finanzas-dos"><div><label htmlFor="redis-origen">Desde</label><select id="redis-origen" value={redistribucion.origen} onChange={(e) => setRedistribucion({ ...redistribucion, origen: e.target.value as Destino })}>{destinos.map((destino) => <option value={destino} key={destino}>{etiqueta(destino)}</option>)}</select></div><div><label htmlFor="redis-destino">Hacia</label><select id="redis-destino" value={redistribucion.destino} onChange={(e) => setRedistribucion({ ...redistribucion, destino: e.target.value as Destino })}>{destinos.map((destino) => <option value={destino} key={destino}>{etiqueta(destino)}</option>)}</select></div></div><label htmlFor="redis-monto">Monto</label><input id="redis-monto" inputMode="decimal" value={redistribucion.monto} onChange={(e) => setRedistribucion({ ...redistribucion, monto: e.target.value })} placeholder="0.00" required /><label htmlFor="redis-descripcion">Descripción (opcional)</label><input id="redis-descripcion" value={redistribucion.descripcion} onChange={(e) => setRedistribucion({ ...redistribucion, descripcion: e.target.value })} maxLength={300} /><button type="submit">Redistribuir dinero</button></fieldset></form></section>
    </div>
    <div className="finanzas-form-grid finanzas-historial-grid"><section className="finanzas-panel"><h2>Movimientos recientes</h2>{datos?.movimientos.length ? <ul className="finanzas-historial">{datos.movimientos.map((item) => <li key={item.id}><div><strong>{etiqueta(item.tipo)}{item.direccion_transferencia ? ` · ${item.direccion_transferencia}` : ''}</strong><small>{item.descripcion || item.destino_dinero || new Date(item.fecha_movimiento).toLocaleDateString('es-PE')}</small></div><b>{item.tipo === 'gasto' || item.direccion_transferencia === 'salida' ? '−' : '+'}{dinero(Number(item.monto))}</b></li>)}</ul> : <p className="finanzas-vacio">No hay movimientos todavía.</p>}</section><section className="finanzas-panel"><h2>Historial de destinos</h2>{datos?.historial.length ? <ul className="finanzas-historial">{datos.historial.map((item) => <li key={item.id}><div><strong>{etiqueta(item.tipo)}</strong><small>{item.origen ? `${etiqueta(item.origen)} → ` : ''}{item.destino ? etiqueta(item.destino) : 'Saldo inicial cero'}</small></div><b>{dinero(Number(item.monto))}</b></li>)}</ul> : <p className="finanzas-vacio">No hay asignaciones todavía.</p>}</section></div>
  </div>
}
