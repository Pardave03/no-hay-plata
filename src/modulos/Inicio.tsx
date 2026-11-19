import { useDinero } from '../servicios/privacidad'

// Montos de ejemplo mientras Inicio no usa datos reales (siguiente etapa).
const tarjetas = [
  { nombre: 'Balance disponible', monto: 8450, icono: '◈', tono: 'morado', nota: 'Resumen general' },
  { nombre: 'Ingresos del mes', monto: 5280, icono: '↗', tono: 'menta', nota: 'Datos de ejemplo' },
  { nombre: 'Gastos del mes', monto: 2340, icono: '↘', tono: 'coral', nota: 'Datos de ejemplo' },
  { nombre: 'Ahorros', monto: 12800, icono: '◇', tono: 'amarillo', nota: 'Datos de ejemplo' },
]

export function Inicio({ nombre }: { nombre: string }) {
  const dinero = useDinero()
  return <>
    <section className="welcome">
      <div><div className="eyebrow">TU RESUMEN FINANCIERO</div><h1>¡Hola, {nombre}! <span>👋</span></h1><p>¿En qué se fue la plata esta vez?</p></div>
    </section>
    <div className="demo-banner"><span className="demo-dot" /> Vista de demostración <span className="demo-separator">·</span> Los montos son ficticios y solo ilustran el diseño.</div>
    <section className="summary" aria-label="Resumen financiero de demostración">
      {tarjetas.map((tarjeta) => <article className={`summary-card ${tarjeta.tono}`} key={tarjeta.nombre}>
        <div className="card-top"><span className="card-icon" aria-hidden="true">{tarjeta.icono}</span><span className="card-spark" aria-hidden="true">✦</span></div>
        <p>{tarjeta.nombre}</p><strong>{dinero(tarjeta.monto)}</strong><small>{tarjeta.nota}</small>
      </article>)}
    </section>
    <section className="placeholder-feature"><span className="feature-icon">✳</span><div><h2>Todo en un solo lugar</h2><p>Explora las secciones del menú para conocer la estructura de tu espacio financiero.</p></div></section>
  </>
}
