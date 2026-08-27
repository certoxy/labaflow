import SharedSidebar from "../SharedSidebar";

export default function OrganizationLayout({children}:{children:React.ReactNode}){
 return <div className="appShell"><SharedSidebar active={undefined}/>{children}</div>;
}
