import SharedSidebar from "../SharedSidebar";

export default function NewOrderLayout({children}:{children:React.ReactNode}){
 return <div className="appShell"><SharedSidebar active="new-order"/>{children}</div>;
}
