import SharedSidebar from "../SharedSidebar";
export default function ProductsLayout({children}:{children:React.ReactNode}){return <div className="appShell"><SharedSidebar active="products"/>{children}</div>}
